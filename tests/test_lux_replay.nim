## An end-to-end episode that writes a replay, re-simulates it from the bytes
## alone, and parses it strictly — for EVERY end reason.

import std/[json, os, osproc, strutils, unicode, unittest]

import lux/[broadcast, global, replay_runtime, replays, sim]
import helpers

type Recorded = object
  path: string
  game: SimServer

proc record(
  config: GameConfig, path: string, stopAtTurn = -1, faultAtTurn = -1
): Recorded =
  ## The server's own record order, exactly: install directives, write the
  ## input packets and the chat records, write the hash, THEN step.
  result.path = path
  var writer = openReplayWriter(path, $config.configJson(), LuxReplaySpec)
  var game = initSimServer(config)
  game.seats[0].joined = true
  game.seats[1].joined = true
  game.seats[0].name = "daveey"
  game.seats[1].name = "daveey-1"
  for seat in 0 .. 1:
    writer.writeJoin(tickTime(0, ReplayFps), seat, game.seats[seat].name,
      seat, "token-" & $seat)
    writer.writeChat(tickTime(0, ReplayFps), seat,
      $registerRecord(seat, cogAlias(seat),
        "lux-ai-" & (if seat == 0: "forester" else: "prospector"),
        "scripted", (if seat == 0: "forester" else: "prospector")))
  writer.writeInputPacket(0, 0, controlPacket(InputStart))
  game.beginPlaying()
  var lastDirective = -1
  while not game.episodeFinished():
    if game.phase == Playing:
      if stopAtTurn >= 0 and game.world.turn == stopAtTurn:
        writer.writeInputPacket(game.tickCount, 0,
          controlPacket(InputWallClockStop))
        writer.writeChat(tickTime(game.tickCount, ReplayFps), 0,
          $(%*{"k": "stop", "turn": game.world.turn, "endRule": "wall_clock"}))
        game.applyWallClockStop()
      elif faultAtTurn >= 0 and game.world.turn == faultAtTurn:
        for cell in 0 ..< game.world.board.cellCount():
          if game.world.cities.teamOfCell[cell] == 1:
            game.world.units.list[0].cell = cell
            break
      elif game.isDirectiveTurn(game.world.turn) and
          game.world.turn != lastDirective:
        lastDirective = game.world.turn
        game.setDirective(0, scriptedDirective(game.world, blForester, 0))
        game.setDirective(1, scriptedDirective(game.world, blProspector, 1))
        for seat in 0 .. 1:
          writer.writeInputPacket(game.tickCount, seat,
            directivePacket(game.world.directiveBytes[seat]))
          writer.writeChat(tickTime(game.tickCount, ReplayFps), 0,
            $game.directive[seat].directiveRecord(game.world.turn, seat,
              cogAlias(seat), newJObject()))
    writer.writeHash(uint32(game.tickCount), game.gameHash())
    game.step()
  writer.writeChat(tickTime(game.tickCount, ReplayFps), 0, game.resultRecord())
  writer.closeReplayWriter()
  result.game = game

proc recordWithLobby(config: GameConfig, path: string, joinTick: int): Recorded =
  ## `server.nim`'s loop for an episode whose seats connect at `joinTick`:
  ## `syncSeats` writes each join record at the tick that seat's socket
  ## appeared, the lobby writes one hash per waiting tick, and `InputStart` is
  ## written at the tick `Playing` actually began — which is
  ## `max(startWaitTicks, joinTick)`, not `startWaitTicks`. Nothing here zeroes
  ## `startWaitTicks`: a lobby LONGER than it is the whole point of the
  ## fixture.
  result.path = path
  var writer = openReplayWriter(path, $config.configJson(), LuxReplaySpec)
  var game = initSimServer(config)
  game.seats[0].name = "daveey"
  game.seats[1].name = "daveey-1"
  var joinWritten: array[2, bool]
  var lastDirective = -1
  while not game.episodeFinished():
    if game.tickCount >= joinTick:
      for seat in 0 .. 1:
        if not game.seats[seat].joined:
          game.seats[seat].joined = true
          game.seats[seat].connected = true
        if not joinWritten[seat]:
          joinWritten[seat] = true
          writer.writeJoin(tickTime(game.tickCount, ReplayFps), seat,
            game.seats[seat].name, seat, "token-" & $seat)
    if game.phase == Lobby:
      let joined = game.seats[0].joined and game.seats[1].joined
      if joined and game.tickCount >= config.startWaitTicks:
        writer.writeInputPacket(game.tickCount, 0, controlPacket(InputStart))
        game.beginPlaying()
      else:
        writer.writeHash(uint32(game.tickCount), game.gameHash())
        inc game.tickCount
        continue
    if game.phase == Playing and game.isDirectiveTurn(game.world.turn) and
        game.world.turn != lastDirective:
      lastDirective = game.world.turn
      game.setDirective(0, scriptedDirective(game.world, blForester, 0))
      game.setDirective(1, scriptedDirective(game.world, blProspector, 1))
      for seat in 0 .. 1:
        writer.writeInputPacket(game.tickCount, seat,
          directivePacket(game.world.directiveBytes[seat]))
    writer.writeHash(uint32(game.tickCount), game.gameHash())
    game.step()
  writer.writeChat(tickTime(game.tickCount, ReplayFps), 0, game.resultRecord())
  writer.closeReplayWriter()
  result.game = game

proc replayCleanly(path: string): tuple[player: ReplayPlayer, sim: SimServer] =
  let data = parseLuxReplay(readFile(path))
  var initialized = initReplayRuntime(data, mismatchQuit = true)
  var
    player = initialized.player
    game = initialized.sim
    tracker = initialized.tracker
    viewer = initGlobalViewerState()
    next: GlobalViewerState
  player.seekReplay(game, 0)
  while game.tickCount < player.maxTick:
    let before = game.tickCount
    let events = advanceReplayFrame(player, game, tracker, [], [])
    discard buildReplayViewerPacket(game, player, tracker, viewer, next, events)
    viewer = next
    if game.tickCount == before:
      break
  (player, game)

suite "lux replay":
  let dir = getTempDir() / "lux-replay-test"
  createDir(dir)

  test "a full scripted episode writes a replay whose every hash re-derives":
    let path = dir / "full_time.replay"
    let recorded = record(fixtureConfig(seed = 42), path)
    check recorded.game.endRule == erlFullTime
    check fileExists(path)
    check getFileSize(path) > 1000
    let played = replayCleanly(path)
    check played.player.hashMismatchTick == -1
    check played.sim.world.turn == recorded.game.world.turn
    check played.sim.world.cities.tileCount(Red) ==
      recorded.game.world.cities.tileCount(Red)
    check played.sim.world.cities.tileCount(Blue) ==
      recorded.game.world.cities.tileCount(Blue)

  test "a lobby LONGER than startWaitTicks re-derives frame by frame":
    ## The recorded lobby is a wall-clock fact: seats that connect at tick 120
    ## make the live game start at 120, and playback must start there too. When
    ## playback seated both seats at construction instead, the re-simulation
    ## started at `startWaitTicks` (48), the chain broke at tick 49 and a
    ## recorded 18-1 episode re-derived as 17-3 — a different game under a
    ## mismatch banner. `startWaitTicks` is left at its SHIPPED value here on
    ## purpose: zeroing it in the fixture is what hid this.
    for joinTick in [0, 49, 120]:
      var config = defaultGameConfig()
      config.seed = 42
      config.mapSize = 16
      check config.startWaitTicks == 48
      let path = dir / ("lobby" & $joinTick & ".replay")
      let recorded = recordWithLobby(config, path, joinTick)
      checkpoint("seats connect at tick " & $joinTick)
      check recorded.game.gameStartTick == max(config.startWaitTicks, joinTick)
      check recorded.game.endRule == erlFullTime
      ## `mismatchQuit = true`: any divergent tick raises, so this asserts the
      ## WHOLE chain, not just the final board.
      let played = replayCleanly(path)
      check played.player.hashMismatchTick == -1
      check played.player.replayStartTick() == recorded.game.gameStartTick
      check played.sim.gameStartTick == recorded.game.gameStartTick
      check played.sim.world.turn == recorded.game.world.turn
      check played.sim.endRule == recorded.game.endRule
      check played.sim.gameHash() == recorded.game.gameHash()
      check played.sim.world.cities.tileCount(Red) ==
        recorded.game.world.cities.tileCount(Red)
      check played.sim.world.cities.tileCount(Blue) ==
        recorded.game.world.cities.tileCount(Blue)

  test "the wall_clock stop re-derives INCLUDING the stop turn":
    let path = dir / "wall_clock.replay"
    let recorded = record(fixtureConfig(seed = 42), path, stopAtTurn = 140)
    check recorded.game.endRule == erlWallClock
    let played = replayCleanly(path)
    check played.player.hashMismatchTick == -1
    check played.sim.endRule == erlWallClock
    check played.sim.world.turn == 140

  test "a sim_fault replay still parses, and the hash chain names the tick":
    ## The fault here is injected OUT OF BAND (a unit teleported onto an
    ## opponent city tile), which is exactly the class of corruption no
    ## re-simulation can derive — so the recorded chain must CATCH it, at the
    ## tick it happened, and the partial replay must still be readable.
    let path = dir / "sim_fault.replay"
    let recorded = record(fixtureConfig(seed = 42), path, faultAtTurn = 90)
    check recorded.game.endRule == erlSimFault
    let data = parseLuxReplay(readFile(path))
    check data.hashes.len > 90
    var initialized = initReplayRuntime(data, mismatchQuit = false)
    var
      player = initialized.player
      game = initialized.sim
      tracker = initialized.tracker
    player.seekReplay(game, 0)
    while game.tickCount < player.maxTick:
      let before = game.tickCount
      discard advanceReplayFrame(player, game, tracker, [], [])
      if game.tickCount == before:
        break
    check player.hashMismatchTick >= 0
    check player.hashMismatchTick <= player.maxTick

  test "the bytes alone yield names, aliases, kinds, config, seed and the result":
    let path = dir / "full_time.replay"
    let data = parseLuxReplay(readFile(path))
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    check data.joins.len == 2
    check data.joins[0].name == "daveey"
    check data.joins[1].name == "daveey-1"
    let config = parseJson(data.configJson)
    check config["seed"].getInt() == 42
    check config["mapSize"].getInt() == 16
    check config["num_agents"].getInt() == 2
    check "tokens" notin config          ## runner-managed, never recorded
    var kinds, directives, results = 0
    for chat in data.chats:
      if not chat.message.startsWith("{"):
        continue
      case parseJson(chat.message){"k"}.getStr()
      of "register": inc kinds
      of "directive": inc directives
      of "result": inc results
      else: discard
    check kinds == 2
    check directives >= 2
    check results == 1

  test "the results key set equals the manifest's results_schema key set":
    let path = dir / "full_time.replay"
    let recorded = parseJson(record(fixtureConfig(seed = 42), path).game
      .luxResultsJson())
    let schema = parseJson(readRepoFile("coworld_manifest_template.json"))[
      "game"]["results_schema"]["properties"]
    for key in ResultsKeys:
      check recorded.hasKey(key)
      check schema.hasKey(key)
    check recorded.len == ResultsKeys.len
    check schema.len == ResultsKeys.len
    for key, _ in schema:
      check key in ResultsKeys

  test "every directive record is inside its caps":
    let data = parseLuxReplay(readFile(dir / "full_time.replay"))
    for chat in data.chats:
      if not chat.message.startsWith("{"):
        continue
      let node = parseJson(chat.message)
      if node{"k"}.getStr() != "directive":
        continue
      check node{"note"}.getStr().runeLen <= MaxNoteRunes
      check node{"workers"}.getInt() in 0 .. MaxWorkers
      check node{"carts"}.getInt() in 0 .. MaxCarts

  test "the derived stream contains a citybuilt, a dusk, a research and a unitbuilt":
    let data = parseLuxReplay(readFile(dir / "full_time.replay"))
    var initialized = initReplayRuntime(data, mismatchQuit = false)
    var
      player = initialized.player
      game = initialized.sim
      tracker = initialized.tracker
      seen: seq[string] = @[]
    player.seekReplay(game, 0)
    while game.tickCount < player.maxTick:
      let before = game.tickCount
      for event in advanceReplayFrame(player, game, tracker, [], []):
        let kind = event{"k"}.getStr()
        if kind notin seen:
          seen.add(kind)
      if game.tickCount == before:
        break
    for wanted in ["citybuilt", "dusk", "research", "unitbuilt"]:
      checkpoint(wanted & " missing from " & $seen)
      check wanted in seen
    ## and the beat set is EXACTLY the four declared kinds
    var beatKinds: seq[string] = @[]
    for beat in player.beats:
      if beat.kind notin beatKinds:
        beatKinds.add(beat.kind)
    for kind in beatKinds:
      check kind in ["dusk", "research", "citylost", "end"]

  test "strict-UTF-8 replay parse with a 4-byte emoji on EVERY cap":
    ## Every capped field filled to exactly its cap with a 4-byte codepoint, and
    ## non-ASCII policy labels, then read back through the Python summariser
    ## under STRICT UTF-8.
    const Emoji = "\u{1F600}"
    proc fill(cap: int): string =
      for _ in 0 ..< cap:
        result.add(Emoji)
    let path = dir / "emoji.replay"
    var config = fixtureConfig(seed = 42)
    config.maxTurns = 40
    var writer = openReplayWriter(path, $config.configJson(), LuxReplaySpec)
    var game = initSimServer(config)
    game.seats[0].joined = true
    game.seats[1].joined = true
    for seat in 0 .. 1:
      game.seats[seat].name = fill(20)
      writer.writeJoin(tickTime(0, ReplayFps), seat, game.seats[seat].name,
        seat, "token-" & $seat)
      writer.writeChat(tickTime(0, ReplayFps), seat,
        $registerRecord(seat, cogAlias(seat),
          fill(MaxPolicyLabelRunes), "llm", "forester"))
    writer.writeInputPacket(0, 0, controlPacket(InputStart))
    game.beginPlaying()
    var lastDirective = -1
    while not game.episodeFinished():
      if game.phase == Playing and game.isDirectiveTurn(game.world.turn) and
          game.world.turn != lastDirective:
        lastDirective = game.world.turn
        for seat in 0 .. 1:
          var directive = scriptedDirective(game.world, blForester, seat)
          directive.note = sanitizeNote(fill(MaxNoteRunes + 40))
          directive.source = dsLlm
          check directive.note.runeLen == MaxNoteRunes
          game.setDirective(seat, directive)
          writer.writeInputPacket(game.tickCount, seat,
            directivePacket(game.world.directiveBytes[seat]))
          writer.writeChat(tickTime(game.tickCount, ReplayFps), 0,
            $directive.directiveRecord(game.world.turn, seat, cogAlias(seat),
              newJObject()))
        writer.writeChat(tickTime(game.tickCount, ReplayFps), 0,
          $(%*{"k": "fallback", "turn": game.world.turn, "seat": 0,
               "attempt": 2, "cause": "parse_error",
               "detail": fill(MaxFallbackDetailRunes)}))
      writer.writeHash(uint32(game.tickCount), game.gameHash())
      game.step()
    writer.writeChat(tickTime(game.tickCount, ReplayFps), 0, game.resultRecord())
    writer.closeReplayWriter()

    ## the Nim reader is strict too
    let data = parseLuxReplay(readFile(path))
    check data.joins[0].name.validateUtf8() == -1
    check parseJson(data.configJson)["seed"].getInt() == 42

    let summary = execCmdEx("python3 " & (repoRoot() / "tools/replay_summary.py") &
      " " & path)
    checkpoint(summary.output)
    check summary.exitCode == 0
    let node = parseJson(summary.output)
    check node["protocol"].getStr() == "lux-ai/v1"
    check node["gameVersion"].getStr() == GameVersion
    check summary.output.validateUtf8() == -1
    check "\\ud" notin summary.output.toLowerAscii()   ## no lone surrogates
    for directive in node["directives"]:
      check directive["note"].getStr().runeLen <= MaxNoteRunes
    check node["fallbacks"].getInt() > 0
