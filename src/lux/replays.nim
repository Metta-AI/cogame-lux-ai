## The `COWLDLUX` binary replay: the writer's record vocabulary, the parser,
## and the deterministic player the browser re-simulates with.
##
## Forked from coworld-ctf's `src/ctf/replays.nim` over bitworld's generic
## codec (`bitworld/replays`), with the magic and game name changed. The one
## structural simplification the Lux rules allow: coworld-ctf keyframes its sim
## every 100 ticks because re-simulating a pixel-space shooter is expensive,
## while a whole 360-turn Lux episode re-simulates in single-digit
## milliseconds — so a SEEK here rewinds to tick 0 and replays, and the
## load-time pre-scan is one extra full re-simulation. No keyframe cache can
## drift out of step with the rules if there is no keyframe cache.
##
## THE MAP IS RE-DERIVED from the seed rather than recorded: it is in
## `gameHash` from turn 0, so a divergence surfaces immediately, which is why
## the file stays around 60 KB.

import std/[json]

import bitworld/replays as codec
import sim

export codec

const
  LuxReplaySpec* = codec.ReplaySpec(
    magic: ReplayMagic,
    formatVersion: ReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: codec.rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: codec.rhoStop)

  InputDirective* = 1'u8
    ## kind byte 1, then the 13 structured directive bytes. LOAD-BEARING:
    ## re-applied before the same turn is stepped.
    ##
    ## The pinned bitworld codec's input record carries ONE byte per record
    ## (`ReplayInput.keys`), so a 14-byte packet is fourteen consecutive input
    ## records at the same tick and player. Parse order is preserved by the
    ## codec, so re-reading them is a concatenation, and the record type stays
    ## the genuine `ReplayInputRecord` rather than a debug-sprite smuggle.
  InputStart* = 2'u8
    ## The tick `Playing` began. Load-bearing: the lobby's length is a
    ## wall-clock fact (when the seats actually connected) that no
    ## re-simulation can derive.
  InputWallClockStop* = 3'u8
    ## The wall-clock stop, applied on BOTH sides by `sim.applyWallClockStop`
    ## before that turn's step (the particle-worlds r2 scar).

  ReplayHalfSpeedIndex* = -1
    ## speedIndex sentinel for 1/2x playback: one turn every other frame.
    ## `replaySpeed()` clamps it back to `PlaybackSpeeds[0]` (1x), so only the
    ## frame parity in `advanceReplayPlayback` ever runs slower than 1x.

type
  Beat* = object
    ## A scrubber marker. A CLOSED set of four kinds, all bounded by
    ## construction: `dusk` (<= 9), `research` (<= 4), `citylost` (throttled to
    ## one per seat per night, <= 18) and `end` (1) — at most 32 markers on a
    ## 360-turn scrubber.
    tick*: int
    turn*: int
    kind*: string
    seat*: int
    label*: string

  ReplayPlayer* = object
    data*: codec.ReplayData
    playing*: bool
    looping*: bool
    skipLulls*: bool
    speedIndex*: int
      ## Index into PlaybackSpeeds, or ReplayHalfSpeedIndex (-1) for the
      ## replay-only 1/2x speed (one turn every other frame).
    halfPhase*: bool
      ## Frame parity while at 1/2x speed: turns advance only on the odd
      ## frames, toggled once per advanceReplayPlayback frame.
    hashIndex*: int
    hashMismatchTick*: int
    hashValidationFailed*: bool
    mismatchQuit*: bool
    maxTick*: int
    startTick*: int
    endHoldFrames*: int
    scanComplete*: bool
    leadSeries*: seq[seq[int]]
      ## [tick, cityTiles0, cityTiles1] change-points across the whole episode,
      ## from the load-time pre-scan, so the city-tile lead graph draws at FULL
      ## WIDTH on the first frame instead of growing in.
    lullSpans*: seq[array[2, int]]
    beats*: seq[Beat]
    chatCursor*: int

func tickOfTime*(time: uint32): int =
  ## The inverse of the codec's `tickTime` at `ReplayFps`. The pinned bitworld
  ## revision exports only the forward direction.
  int((int64(time) * int64(ReplayFps) + 500'i64) div 1000'i64)

proc parseLuxReplay*(bytes: string): codec.ReplayData =
  codec.parseReplayBytes(bytes, LuxReplaySpec)

proc directivePacket*(bytes: array[13, uint8]): seq[uint8] =
  result = newSeq[uint8](1 + bytes.len)
  result[0] = InputDirective
  for i, value in bytes:
    result[i + 1] = value

proc controlPacket*(kind: uint8): seq[uint8] = @[kind]

proc writeInputPacket*(
  writer: var codec.ReplayWriter, tick, player: int, packet: openArray[uint8]
) =
  ## One logical input packet as consecutive one-byte input records.
  for value in packet:
    writer.writeInput(codec.ReplayInput(
      time: codec.tickTime(tick, ReplayFps),
      player: uint8(player),
      keys: value))

proc replaySpeed*(player: ReplayPlayer): int =
  ## The integer per-frame step budget (1 while at 1/2x — the fractional pace
  ## lives in advanceReplayPlayback's frame parity).
  PlaybackSpeeds[clamp(player.speedIndex, 0, PlaybackSpeeds.high)]

proc replayDisplaySpeed*(player: ReplayPlayer): float =
  ## The speed the chrome shows: 0.5 at half speed, else the integer speed.
  if player.speedIndex == ReplayHalfSpeedIndex: 0.5
  else: float(player.replaySpeed())

proc replayMaxTick*(player: ReplayPlayer): int = player.maxTick

proc replayStartTick*(player: ReplayPlayer): int = max(0, player.startTick)

proc simFromReplay*(data: codec.ReplayData): SimServer =
  var config = defaultGameConfig()
  config.update(parseJson(data.configJson))
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  result.world.eventLoggingEnabled = false
  ## The seats are NOT seated here: a seat becomes `joined` at the tick its
  ## join record was written (`applyRecordsAt`), because the lobby's length is
  ## a wall-clock fact and the `Lobby` auto-start reads `joined`. Seating them
  ## at construction starts playback at `startWaitTicks` no matter when the
  ## sockets actually appeared, which re-derives a DIFFERENT game whenever the
  ## live lobby ran longer than that. Names and slots are presentation-only
  ## (not hashed), so they are restored up front for the pre-start frames.
  for join in data.joins:
    let seat = int(join.player)
    if seat in 0 .. 1:
      result.seats[seat].name = join.name
      result.seats[seat].slot = join.slot

proc applyChatRecord(player: var ReplayPlayer, sim: var SimServer, message: string) =
  ## Chat records are PRESENTATION ONLY and are re-applied into non-hashed
  ## fields — with the single documented exception of `stop`, which rides the
  ## INPUT stream, not this one.
  if message.len == 0 or message[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(message)
  except CatchableError:
    return
  case node{"k"}.getStr()
  of "register":
    let seat = node{"seat"}.getInt(-1)
    if seat in 0 .. 1:
      sim.seats[seat].policyLabel = node{"policy"}.getStr()
      sim.seats[seat].isLlm = node{"kind"}.getStr() == "llm"
      sim.seats[seat].baseline = node{"baseline"}.getStr()
      sim.seats[seat].registered = true
  of "directive":
    let seat = node{"seat"}.getInt(-1)
    if seat in 0 .. 1:
      sim.directive[seat].note = node{"note"}.getStr()
      sim.directive[seat].latencyMs = node{"latency_ms"}.getInt()
      case node{"source"}.getStr()
      of "llm": sim.directive[seat].source = dsLlm
      of "fallback": sim.directive[seat].source = dsFallback
      else: sim.directive[seat].source = dsScripted
      if sim.directive[seat].source == dsLlm:
        inc sim.llmTurns[seat]
  of "fallback":
    let seat = node{"seat"}.getInt(-1)
    if seat in 0 .. 1 and node{"attempt"}.getInt() >= 2:
      inc sim.fallbackTurns[seat]
  else:
    discard

proc applyRecordsAt(player: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Every record whose recorded tick is this one, applied BEFORE the tick is
  ## stepped. Joins first (they are what the lobby waits on, and the live loop
  ## syncs the seats before it tests the lobby), then inputs (load-bearing),
  ## then chats (presentation).
  for join in player.data.joins:
    let seat = int(join.player)
    if seat in 0 .. 1 and tickOfTime(join.time) == tick:
      sim.seats[seat].joined = true
      sim.seats[seat].connected = true
  var stream: array[2, seq[uint8]]
  for input in player.data.inputs:
    if tickOfTime(input.time) != tick:
      continue
    if int(input.player) in 0 .. 1:
      stream[int(input.player)].add(input.keys)
  for seat in 0 .. 1:
    var i = 0
    while i < stream[seat].len:
      case stream[seat][i]
      of InputDirective:
        if i + 13 < stream[seat].len:
          sim.applyDirectiveBytes(seat, stream[seat][i + 1 .. i + 13])
        i += 14
      of InputStart:
        sim.beginPlaying()
        inc i
      of InputWallClockStop:
        sim.applyWallClockStop()
        inc i
      else:
        inc i
  for chat in player.data.chats:
    if tickOfTime(chat.time) == tick:
      player.applyChatRecord(sim, chat.message)

proc checkReplayHash(player: var ReplayPlayer, sim: SimServer, tick: int) =
  ## One recorded `gameHash` per tick is the integrity chain: a single
  ## divergent bit is caught at the tick it happens and surfaced as
  ## `mismatchTick` in `#mmwarn`.
  while player.hashIndex < player.data.hashes.len and
      int(player.data.hashes[player.hashIndex].tick) < tick:
    inc player.hashIndex
  if player.hashIndex >= player.data.hashes.len:
    return
  let recorded = player.data.hashes[player.hashIndex]
  if int(recorded.tick) != tick:
    return
  inc player.hashIndex
  if recorded.hash == sim.gameHash():
    return
  if not player.hashValidationFailed:
    player.hashValidationFailed = true
    player.hashMismatchTick = tick
  if player.mismatchQuit:
    raise newException(LuxError, "replay hash mismatch at tick " & $tick)

proc stepReplay*(player: var ReplayPlayer, sim: var SimServer) =
  ## One replay tick: apply this tick's records, step, then compare hashes.
  if sim.tickCount > player.maxTick:
    return
  let tick = sim.tickCount
  player.applyRecordsAt(sim, tick)
  ## The writer records the hash AFTER the tick's records are installed and
  ## BEFORE the tick is stepped, so playback must compare at the same instant.
  player.checkReplayHash(sim, tick)
  sim.step()

proc rewind(player: var ReplayPlayer, sim: var SimServer) =
  ## A rewind rebuilds the sim from the recorded config, so it must carry the
  ## caller's event-logging choice across — otherwise the first seek silently
  ## turns the broadcast event stream off for the rest of the session.
  let logging = sim.gameEventLoggingEnabled
  sim = simFromReplay(player.data)
  sim.gameEventLoggingEnabled = logging
  sim.world.eventLoggingEnabled = logging
  player.hashIndex = 0

proc seekReplay*(player: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## A whole 360-turn episode re-simulates in single-digit milliseconds, so a
  ## seek REWINDS to tick 0 and replays — there is no keyframe cache to drift.
  let target = clamp(tick, 0, player.maxTick)
  player.rewind(sim)
  while sim.tickCount < target:
    let before = sim.tickCount
    player.stepReplay(sim)
    if sim.tickCount == before:
      break
  player.endHoldFrames = 0

proc isLullTick*(player: ReplayPlayer, tick: int): bool =
  for span in player.lullSpans:
    if tick >= span[0] and tick <= span[1]:
      return true
  false

proc beatLabel(kind: string, seat, turn, amount: int): string =
  let side = if seat == 0: "RED" else: "BLUE"
  case kind
  of "dusk": "Night " & $amount & " falls at turn " & $turn
  of "research":
    side & " unlocks " & (if amount >= UraniumResearch: "URANIUM" else: "COAL") &
      " at turn " & $turn
  of "citylost": side & " loses a city at turn " & $turn
  of "end": "Final turn " & $turn
  else: kind

proc runScan(player: var ReplayPlayer) =
  ## The load-time pre-scan: re-simulate the whole episode once, headlessly,
  ## recording the per-turn city-tile counts, the beat turns and the lull
  ## spans, then reset. That is what lets the lead graph and the scrubber beats
  ## draw at FULL WIDTH on the first frame instead of growing in.
  var sim = simFromReplay(player.data)
  sim.gameEventLoggingEnabled = true
  sim.world.eventLoggingEnabled = true
  var
    scanner = ReplayPlayer(data: player.data, maxTick: player.maxTick)
    lastLead = @[-1, -1]
    beatTicks: seq[int] = @[]
    lostThisNight: array[2, int]
  player.leadSeries = @[]
  player.beats = @[]
  player.startTick = -1
  while sim.tickCount <= player.maxTick:
    let before = sim.tickCount
    let eventsBefore = sim.world.events.len
    scanner.stepReplay(sim)
    if sim.tickCount == before:
      break
    if player.startTick < 0 and sim.phase == Playing:
      player.startTick = before
    let lead = @[sim.world.cities.tileCount(Red), sim.world.cities.tileCount(Blue)]
    if lead != lastLead:
      player.leadSeries.add(@[before, lead[0], lead[1]])
      lastLead = lead
    for i in eventsBefore ..< sim.world.events.len:
      let event = sim.world.events[i]
      case event.kind
      of Dusk:
        for seat in 0 .. 1:
          lostThisNight[seat] = 0
        player.beats.add(Beat(tick: before, turn: sim.world.turn, kind: "dusk",
          seat: -1, label: beatLabel("dusk", -1, sim.world.turn, event.amount + 1)))
        beatTicks.add(before)
      of Research:
        player.beats.add(Beat(tick: before, turn: sim.world.turn,
          kind: "research", seat: event.seat,
          label: beatLabel("research", event.seat, sim.world.turn, event.amount)))
        beatTicks.add(before)
      of CityLost:
        if event.seat in 0 .. 1 and lostThisNight[event.seat] == 0:
          inc lostThisNight[event.seat]
          player.beats.add(Beat(tick: before, turn: sim.world.turn,
            kind: "citylost", seat: event.seat,
            label: beatLabel("citylost", event.seat, sim.world.turn, event.amount)))
        beatTicks.add(before)
      of CityBuilt:
        beatTicks.add(before)
      else:
        discard
    if sim.phase == GameOver:
      player.beats.add(Beat(tick: sim.tickCount, turn: sim.world.turn,
        kind: "end", seat: sim.outcome.winner,
        label: beatLabel("end", sim.outcome.winner, sim.world.turn, 0)))
      break
  ## The scan IS a whole-episode integrity walk, so carry its verdict onto the
  ## player: a divergent tick then lights `#mmwarn` at LOAD instead of only
  ## when presentation playback happens to reach it.
  if scanner.hashValidationFailed and not player.hashValidationFailed:
    player.hashValidationFailed = true
    player.hashMismatchTick = scanner.hashMismatchTick
  if player.startTick < 0:
    player.startTick = 0
  # Lull spans: >= 40 consecutive turns with no beat-worthy event.
  const LullLeadTicks = 4
  const MinLullTicks = 40
  var cursor = player.replayStartTick()
  var sorted = beatTicks
  for a in 0 ..< sorted.len:
    for b in a + 1 ..< sorted.len:
      if sorted[b] < sorted[a]:
        swap(sorted[a], sorted[b])
  player.lullSpans = @[]
  for tick in sorted:
    if tick - LullLeadTicks - cursor >= MinLullTicks:
      player.lullSpans.add([cursor + LullLeadTicks, tick - LullLeadTicks])
    cursor = max(cursor, tick + LullLeadTicks)
  if player.maxTick - cursor >= MinLullTicks:
    player.lullSpans.add([cursor, player.maxTick - LullLeadTicks])
  player.scanComplete = true

proc initReplayPlayer*(data: codec.ReplayData): ReplayPlayer =
  result.data = data
  result.playing = true
  result.looping = false
  result.skipLulls = true
  result.speedIndex = 0
  result.hashMismatchTick = -1
  result.startTick = -1
  result.maxTick = 0
  for hash in data.hashes:
    result.maxTick = max(result.maxTick, int(hash.tick))
  result.runScan()

proc applySpeedCommand*(speedIndex: var int, command: char) =
  ## One command from the shared chrome's speed→command map, which sends the
  ## SPEED VALUE's character ('6' is 16x), not an index. '5' selects the 1/2x
  ## replay crawl (ReplayHalfSpeedIndex), and '-' floors there.
  case command
  of '+', '=':
    speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    speedIndex = max(speedIndex - 1, ReplayHalfSpeedIndex)
  of '5':
    speedIndex = ReplayHalfSpeedIndex
  of '1':
    speedIndex = 0
  of '2':
    speedIndex = 1
  of '4':
    speedIndex = 2
  of '8':
    speedIndex = 3
  of '6':
    speedIndex = 4
  else:
    discard

proc applyReplayCommand*(
  player: var ReplayPlayer, sim: var SimServer, command: char
) =
  ## The starter's transport vocabulary; the speed characters are the shared
  ## chrome's speed→command map (applySpeedCommand above).
  case command
  of ' ': player.playing = not player.playing
  of 'r': player.seekReplay(sim, player.replayStartTick())
  of '[': player.seekReplay(sim, max(player.replayStartTick(), sim.tickCount - ReplayFps))
  of ']': player.seekReplay(sim, min(player.maxTick, sim.tickCount + 5 * ReplayFps))
  of 'e': player.seekReplay(sim, player.maxTick)
  of 'l': player.looping = not player.looping
  of 'f': player.skipLulls = not player.skipLulls
  of '+', '=', '-', '_', '1', '2', '4', '5', '8', '6':
    applySpeedCommand(player.speedIndex, command)
  else:
    discard

proc applyReplaySeek*(
  player: var ReplayPlayer, sim: var SimServer, tick: int
) =
  player.seekReplay(sim, tick)

proc endHoldSecondsLeft*(player: ReplayPlayer): int =
  (player.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(
  player: var ReplayPlayer, sim: var SimServer
) =
  ## One PRESENTATION frame. A lull is fast-forwarded at `LullSpeedBoost`; the
  ## final frame is HELD so the endcard is readable before a looping replay
  ## restarts. At 1/2x a turn is spent only every other frame (halfPhase
  ## parity), so the toggle is unconditional — the FIRST statement — to keep
  ## the parity clock ticking through pauses.
  const LullSpeedBoost = 8
  player.halfPhase = not player.halfPhase
  if not player.playing:
    return
  if sim.tickCount >= player.maxTick:
    if player.endHoldFrames > 0:
      dec player.endHoldFrames
      return
    if player.looping:
      player.seekReplay(sim, player.replayStartTick())
      player.endHoldFrames = 0
    return
  var steps = player.replaySpeed()
  if player.skipLulls and player.isLullTick(sim.tickCount):
    steps = min(64, steps * LullSpeedBoost)
  elif player.speedIndex == ReplayHalfSpeedIndex:
    steps = (if player.halfPhase: 1 else: 0)
  for _ in 0 ..< steps:
    if sim.tickCount >= player.maxTick:
      player.endHoldFrames = ReplayFps * 10
      break
    player.stepReplay(sim)

proc cancelEndHold*(player: var ReplayPlayer) =
  player.endHoldFrames = 0

proc beatsJson*(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for beat in player.beats:
    result.add(%*{
      "t": beat.tick,
      "turn": beat.turn,
      "k": beat.kind,
      "seat": beat.seat,
      "label": beat.label
    })

proc lullSpansJson*(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for span in player.lullSpans:
    result.add(%[span[0], span[1]])

proc leadSeriesJson*(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for point in player.leadSeries:
    result.add(%point)
