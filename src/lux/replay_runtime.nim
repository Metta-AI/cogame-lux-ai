## The deterministic replay runtime shared by the native replay route and the
## wasm bundle. Forked from coworld-ctf's `src/ctf/replay_runtime.nim`.

import std/json

import broadcast, global, replays, sim

type
  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer
    tracker*: BroadcastTracker

proc initReplayRuntime*(
  data: ReplayData, mismatchQuit: bool, gameEventLoggingEnabled = true
): InitializedReplay =
  ## Constructs and starts playback from the RECORDED config. The whole-match
  ## pre-scan (city-tile lead series, beat turns, lull spans) runs inside
  ## `initReplayPlayer`: a 360-turn Lux episode re-simulates in single-digit
  ## milliseconds, so the lead graph and the scrubber beats are complete before
  ## the first frame is drawn instead of growing in.
  result.player = initReplayPlayer(data)
  result.sim = simFromReplay(data)
  result.sim.gameEventLoggingEnabled = gameEventLoggingEnabled
  result.sim.world.eventLoggingEnabled = gameEventLoggingEnabled
  result.config = result.sim.config
  result.player.mismatchQuit = mismatchQuit
  result.player.seekReplay(result.sim, result.player.replayStartTick())
  result.player.playing = true
  result.tracker = initBroadcastTracker()

proc advanceReplayFrame*(
  player: var ReplayPlayer,
  sim: var SimServer,
  tracker: var BroadcastTracker,
  seekTicks: openArray[int],
  commands: openArray[char]
): JsonNode =
  ## Applies viewer controls and advances one public presentation frame.
  var didSeek = false
  for seekTick in seekTicks:
    player.applyReplaySeek(sim, seekTick)
    didSeek = true
  for command in commands:
    let before = sim.tickCount
    player.applyReplayCommand(sim, command)
    if sim.tickCount != before:
      didSeek = true
  if didSeek:
    tracker.resync(sim)
    player.cancelEndHold()
  let eventsBefore = sim.world.events.len
  player.advanceReplayPlayback(sim)
  discard eventsBefore
  result = newJArray()
  sim.stepEvents(tracker, result)

proc buildReplayViewerPacket*(
  sim: var SimServer,
  player: ReplayPlayer,
  tracker: var BroadcastTracker,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  events: JsonNode
): seq[uint8] =
  ## The board update plus the chrome JSON, in one packet.
  result = sim.buildBoardPacket(state, nextState)
  let sendLead = not state.momentumSent and player.scanComplete
  if sendLead:
    nextState.momentumSent = true
  let stateJson = sim.buildStateJson(
    tracker,
    events,
    player.playing,
    player.replayDisplaySpeed(),
    player.replayMaxTick(),
    player.looping,
    true,
    player.hashMismatchTick,
    player.replayStartTick(),
    player.skipLulls and player.playing and player.isLullTick(sim.tickCount),
    player.skipLulls,
    if sendLead: player.leadSeriesJson() else: nil,
    if sendLead: player.lullSpansJson() else: nil,
    if sendLead: player.beatsJson() else: nil)
  result.addChrome(stateJson)
