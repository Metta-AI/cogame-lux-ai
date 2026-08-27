import
  std/json,
  lux/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  replay: ReplayPlayer
  game: SimServer
  viewer: GlobalViewerState
  tracker: BroadcastTracker
  packet: seq[uint8]
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 — allocation failure aborts the runtime loudly —
## and this fixed buffer, stamped BEFORE each risky phase, stays readable from
## JS after the abort (aborting kills the call stack, not the linear memory),
## so the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string  ## prebuilt once per load; re-stamped every frame

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  var nextViewer: GlobalViewerState
  packet = buildReplayViewerPacket(
    game, replay, tracker, viewer, nextViewer, events)
  viewer = nextViewer

proc luxLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "lux_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseLuxReplay(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime and pre-scan the episode")
    ## The load-time PRE-SCAN lives inside initReplayRuntime: it re-simulates
    ## the whole episode once headlessly (360 turns of integer work —
    ## single-digit milliseconds in wasm), records the per-turn city-tile
    ## counts, the night spans, the lull spans and the beat turns, then resets
    ## and renders frame 0. That is what lets the city-tile lead graph and the
    ## scrubber beats draw at FULL WIDTH on the first frame.
    ##
    ## Match the native replay server default: keep a historical replay usable
    ## after the first integrity mismatch and surface the warning in the shared
    ## replay chrome.
    var initialized = initReplayRuntime(
      replayData,
      mismatchQuit = false,
      gameEventLoggingEnabled = true
    )
    game = move(initialized.sim)
    replay = move(initialized.player)
    tracker = move(initialized.tracker)
    viewer = initGlobalViewerState()
    runtimeLoaded = true
    let mapNote = " (board " & $game.world.board.size & "x" &
      $game.world.board.size & ")"
    frameStage = "advance replay" & mapNote
    stampStage("render first frame" & mapNote)
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc luxInput(data: ptr uint8, length: cint) {.exportc: "lux_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc luxFrame(): cint {.exportc: "lux_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    let events = advanceReplayFrame(
      replay,
      game,
      tracker,
      seekTicks,
      viewer.replayCommands
    )
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc luxPacketPointer(): ptr uint8 {.exportc: "lux_packet_ptr", cdecl.} =
  if packet.len == 0:
    nil
  else:
    packet[0].addr

proc luxPacketLength(): cint {.exportc: "lux_packet_len", cdecl.} =
  cint(packet.len)

proc luxMismatchTick(): cint {.exportc: "lux_mismatch_tick", cdecl.} =
  if runtimeLoaded:
    cint(replay.hashMismatchTick)
  else:
    -1

proc luxErrorPointer(): ptr uint8 {.exportc: "lux_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc luxErrorLength(): cint {.exportc: "lux_error_len", cdecl.} =
  cint(lastError.len)

proc luxStagePointer(): ptr uint8 {.exportc: "lux_stage_ptr", cdecl.} =
  ## The progress note (see stageNote above). Unlike lux_error_*, this stays
  ## valid after an allocation-failure abort, so JS can report what the runtime
  ## was doing when the address space ran out.
  if stageNoteLen == 0:
    nil
  else:
    cast[ptr uint8](stageNote[0].addr)

proc luxStageLength(): cint {.exportc: "lux_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the baked board images, the sim and the replay — everything —
  # while the wasm module stays alive and JS keeps calling lux_load_replay /
  # lux_frame. The whole session then runs on freed globals: replay hashes get
  # overwritten by later allocations (spurious "REPLAY HASH MISMATCH") and
  # seeks crash out of bounds. Unwinding main through emscripten's
  # live-runtime exit skips the destructor epilogue entirely, so globals stay
  # valid for the life of the page.
  emscriptenExitWithLiveRuntime()
