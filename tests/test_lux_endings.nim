## `results.reason` and `results.endRule` are closed enums, and each end rule
## fires exactly when it should.

import std/[json, strutils, unittest]

import lux/sim
import helpers

const
  Reasons = ["complete", "deadline", "fault"]
  Rules = ["full_time", "eliminated", "wall_clock", "sim_fault", "host_error"]

suite "lux endings":
  test "full_time at exactly maxTurns, and not the turn before":
    var game = scriptedEpisode(fixtureConfig(seed = 42))
    check game.reason == erComplete
    check game.endRule == erlFullTime
    check game.world.turn == game.config.maxTurns
    ## and the turn before was still Playing
    var earlier = initSimServer(fixtureConfig(seed = 42))
    earlier.seats[0].joined = true
    earlier.seats[1].joined = true
    var lastDirective = -1
    while earlier.world.turn < earlier.config.maxTurns - 1:
      if earlier.phase == Playing and
          earlier.isDirectiveTurn(earlier.world.turn) and
          earlier.world.turn != lastDirective:
        lastDirective = earlier.world.turn
        earlier.setDirective(0, scriptedDirective(earlier.world, blForester, 0))
        earlier.setDirective(1, scriptedDirective(earlier.world, blProspector, 1))
      earlier.step()
    check earlier.phase == Playing
    check earlier.endRule == erlNone

  test "eliminated fires the turn a side reaches zero tiles and zero units":
    var config = fixtureConfig(seed = 2024)
    var game = scriptedEpisode(config)
    check game.reason == erComplete
    check game.endRule == erlEliminated
    check (game.finalStanding.cityTiles[0] + game.finalStanding.units[0] == 0) or
      (game.finalStanding.cityTiles[1] + game.finalStanding.units[1] == 0)

  test "wall_clock settles with a rankable result":
    var game = initSimServer(fixtureConfig(seed = 7))
    game.seats[0].joined = true
    game.seats[1].joined = true
    for _ in 0 ..< 200:
      game.step()
    game.applyWallClockStop()
    check game.reason == erDeadline
    check game.endRule == erlWallClock
    let results = parseJson(game.luxResultsJson())
    check results["scores"][0].getFloat() + results["scores"][1].getFloat() == 1.0
    check results["turnsPlayed"].getInt() > 0

  test "sim_fault on a forced invariant trip, with the artifacts still settled":
    var game = initSimServer(fixtureConfig(seed = 42))
    game.seats[0].joined = true
    game.seats[1].joined = true
    for _ in 0 ..< 60:
      game.step()
    ## Force a violation the guard is required to catch: a unit on an opponent
    ## city tile.
    let enemyTile = block:
      var found = -1
      for cell in 0 ..< game.world.board.cellCount():
        if game.world.cities.teamOfCell[cell] == 1:
          found = cell
          break
      found
    check enemyTile >= 0
    game.world.units.list[0].cell = enemyTile
    game.step()
    check game.reason == erFault
    check game.endRule == erlSimFault
    check game.stopDetail.len > 0
    let results = parseJson(game.luxResultsJson())
    check results["reason"].getStr() == "fault"
    check results["endRule"].getStr() == "sim_fault"

  test "reason and endRule are always members of their declared enums":
    for seed in [42, 7, 99, 1234, 2024, 1734029581]:
      let game = scriptedEpisode(fixtureConfig(seed = seed))
      let results = parseJson(game.luxResultsJson())
      check results["reason"].getStr() in Reasons
      check results["endRule"].getStr() in Rules

  test "every enum value the sim can emit is declared":
    for reason in EndReason:
      check ($reason) in Reasons
    for rule in EndRule:
      if rule == erlNone:
        continue
      check ($rule) in Rules
