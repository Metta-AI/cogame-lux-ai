## The decision layer: the parallel batch, the bounded waits, the guards, and
## the fallback ladder — against a FAKE client, so no test touches the network.

import std/[json, monotimes, strutils, times, unittest]

import lux/[decide, llm, sim, sim_config]
import helpers

suite "lux engine":
  test "sim_config.validate rejects a sub-second deadline and an over-budget turn":
    var config = defaultGameConfig()
    config.validate()
    var fractional = defaultGameConfig()
    fractional.attempt1Ms = 4500
    expect ConfigError:
      fractional.validate()
    var retryFractional = defaultGameConfig()
    retryFractional.retryMs = 2500
    expect ConfigError:
      retryFractional.validate()
    var over = defaultGameConfig()
    over.attempt1Ms = 8000
    over.retryMs = 5000
    over.turnBudgetMs = 11000
    expect ConfigError:
      over.validate()
    var slow = defaultGameConfig()
    slow.wallClockBudgetSeconds = 900
    expect ConfigError:
      slow.validate()

  test "the shipped timing fits inside 60 % of episodeTimeoutSeconds":
    let config = defaultGameConfig()
    check config.attempt1Ms == 7000
    check config.retryMs == 3000
    check config.turnBudgetMs == 11000
    check config.turnSpacingMs == 6000
    check config.wallClockBudgetSeconds == 660
    let directiveTurns = (config.maxTurns + config.directiveEvery - 1) div
      config.directiveEvery
    check directiveTurns == 36
    ## The worst per-turn wall clock is the CODE's, not the note's 11 s:
    ## `turnStart` is taken at the top of `decide.turn`, the rate-floor sleep
    ## of up to turnSpacingMs happens AFTER it, and the budget is checked
    ## BEFORE each attempt rather than bounding the attempt. So the longest a
    ## turn can run is 6 s of spacing + one 7 s attempt-1 timeout = 13 s, and
    ## then the check fires, records the timeout and breaks.
    let worstTurnMs = config.turnSpacingMs + config.attempt1Ms
    check worstTurnMs == 13000
    check worstTurnMs > config.turnBudgetMs
    let worst = directiveTurns * worstTurnMs
    check worst div 1000 == 468
    ## + 3 s of sim + the 100 s lobby cap + 20 s of artifact writing.
    check worst div 1000 + 3 + 100 + 20 < config.wallClockBudgetSeconds
    ## The wall-clock stop is checked at the TOP of the server loop, so the
    ## episode can overshoot its own budget by one more worst-case turn and
    ## must STILL land inside 60 % of episodeTimeoutSeconds (720 s of 1200).
    check config.wallClockBudgetSeconds + worstTurnMs div 1000 <= 720

  test "with no credentials every directive turn is a recorded fallback, and 360 turns still run":
    ## The engine is constructed with no key in the environment, so the client
    ## disables itself and the whole episode plays scripted with no network wait.
    var game = initSimServer(fixtureConfig(seed = 42))
    game.seats[0].joined = true
    game.seats[1].joined = true
    var engine = initDecisionEngine(game)
    engine.seats[0].isLlm = true
    engine.seats[1].isLlm = true
    check engine.client.disabled
    var records: seq[string] = @[]
    var lastDirective = -1
    let started = getMonoTime()
    while not game.episodeFinished():
      if game.phase == Playing and game.isDirectiveTurn(game.world.turn) and
          game.world.turn != lastDirective:
        lastDirective = game.world.turn
        for record in engine.turn(game, 0):
          records.add(record)
      game.step()
    check game.world.turn == game.config.maxTurns or
      game.endRule == erlEliminated
    ## Bounded: no credentials means no network wait at all.
    check (getMonoTime() - started).inSeconds < 30
    var fallbacks = 0
    for record in records:
      if parseJson(record){"k"}.getStr() == "fallback":
        inc fallbacks
    check fallbacks >= 2
    check game.fallbackTurns[0] > 0
    check game.fallbackTurns[1] > 0
    check game.llmTurns == [0, 0]

  test "a scripted seat is NOT a fallback and writes no fallback record":
    var game = initSimServer(fixtureConfig(seed = 42))
    var engine = initDecisionEngine(game)
    let records = engine.turn(game, 0)
    var fallbacks = 0
    for record in records:
      if parseJson(record){"k"}.getStr() == "fallback":
        inc fallbacks
    check fallbacks == 0
    check game.fallbackTurns == [0, 0]
    ## and both seats still got a legal directive, plus a directive record each
    var directives = 0
    for record in records:
      if parseJson(record){"k"}.getStr() == "directive":
        inc directives
    check directives == 2

  test "the budget guard fires and the episode still ends complete":
    var game = initSimServer(fixtureConfig(seed = 42))
    var engine = initDecisionEngine(game)
    engine.seats[0].isLlm = true
    engine.seats[1].isLlm = true
    let records = engine.turn(game, game.config.wallClockBudgetSeconds - 5)
    check engine.llmOff
    var guarded = false
    for record in records:
      if parseJson(record){"k"}.getStr() == "budget_guard":
        guarded = true
    check guarded
    ## and from here on every seat plays the scripted layer at microseconds
    let later = engine.turn(game, game.config.wallClockBudgetSeconds - 5)
    for record in later:
      check parseJson(record){"k"}.getStr() != "budget_guard"

  test "the rolling request counter caps a double-retry turn":
    var game = initSimServer(fixtureConfig(seed = 42))
    var engine = initDecisionEngine(game)
    engine.seats[0].isLlm = true
    engine.seats[1].isLlm = true
    for _ in 0 ..< 28:
      engine.requestTimes.add(getMonoTime())
    let records = engine.turn(game, 0)
    var rateGuarded = false
    for record in records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "fallback" and
          node{"cause"}.getStr() == "rate_guard":
        rateGuarded = true
    check rateGuarded

  test "a disconnected seat plays forester and revives on reconnect":
    var game = initSimServer(fixtureConfig(seed = 42))
    var engine = initDecisionEngine(game)
    engine.seats[0].isLlm = true
    game.seats[0].dead = true
    let records = engine.turn(game, 0)
    var cause = ""
    for record in records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "fallback":
        cause = node{"cause"}.getStr()
    check cause == "disconnected"
    ## The installed directive IS forester's, only tagged as a fallback source.
    var expected = foresterDirective(game.world, 0)
    expected.source = dsFallback
    check game.directive[0] == expected
    game.seats[0].dead = false
    discard engine.turn(game, 0)
    check game.fallbackTurns[0] >= 1

  test "no unit is unactuated on any turn after turn 0":
    var game = scriptedEpisode(fixtureConfig(seed = 1734029581))
    check game.world.turn > 100
    ## `test_lux_micro` asserts the per-turn property; this is the whole-episode
    ## restatement: the episode completed without the guard tripping.
    check game.reason == erComplete

  test "BOTH seats go out in ONE parallel batch, never sequentially":
    ## lux-ai is a simultaneous-decision game. A structural assertion, because
    ## the regression it guards against — one `makeRequests` per seat — is a
    ## SHAPE, not a value: every open seat must be posted into one
    ## `RequestBatch` and that batch handed to a single `makeRequests`.
    let source = readRepoFile("src/lux/decide.nim")
    check source.count("makeRequests") == 1
    let
      declaration = source.find("var batch: RequestBatch")
      loop = source.find("for seat in open:", declaration)
      post = source.find("batch.post(", loop)
      call = source.find("makeRequests(", post)
    check declaration >= 0
    check loop > declaration          ## the batch is built before the loop
    check post > loop                 ## every open seat is posted INTO it
    check call > post                 ## and the one call comes after the loop
    ## and nothing between the post and the call issues its own request
    check "makeRequests" notin source[loop ..< post]

  test "the stop, budget-guard and fallback records are well-formed JSON":
    check parseJson(stopRecord(214))["endRule"].getStr() == "wall_clock"
    check parseJson(budgetGuardRecord(214, 30))["remaining_s"].getInt() == 30
    let fallback = parseJson(fallbackRecord(10, 1, 2, "timeout", "detail"))
    check fallback["cause"].getStr() == "timeout"
    check fallback["attempt"].getInt() == 2
