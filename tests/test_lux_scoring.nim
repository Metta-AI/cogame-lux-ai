## The winner ladder and its SIGN.

import std/[random, unittest]

import lux/sim
import helpers

suite "lux scoring":
  test "scores[0] + scores[1] == 1.0 on 5 000 randomised end states":
    var rng = initRand(20260827)
    for _ in 0 ..< 5000:
      var standing: Standing
      for seat in 0 .. 1:
        standing.cityTiles[seat] = rng.rand(0 .. 40)
        standing.units[seat] = rng.rand(0 .. 40)
        standing.fuel[seat] = int64(rng.rand(0 .. 1_000_000))
      let outcome = settle(standing)
      check outcome.scoreOf(0) + outcome.scoreOf(1) == 1.0
      check outcome.scoreOf(0) >= 0.0
      check outcome.scoreOf(1) >= 0.0
      check outcome.winOf(0) == (outcome.scoreOf(0) == 1.0)
      check outcome.winOf(1) == (outcome.scoreOf(1) == 1.0)
      check (outcome.winner < 0) == (outcome.scoreOf(0) == 0.5)

  test "the ladder resolves in order: city tiles, then units, then fuel, then a tie":
    check settle(Standing(cityTiles: [3, 2], units: [0, 9],
      fuel: [0, 99])).winner == 0
    check settle(Standing(cityTiles: [2, 2], units: [1, 9],
      fuel: [99, 0])).winner == 1
    check settle(Standing(cityTiles: [2, 2], units: [3, 3],
      fuel: [10, 9])).winner == 0
    check settle(Standing(cityTiles: [2, 2], units: [3, 3],
      fuel: [9, 9])).winner == -1

  test "a deadline episode is scored by the same ladder and is never zeroed":
    var config = fixtureConfig(seed = 1734029581)
    var game = initSimServer(config)
    game.seats[0].joined = true
    game.seats[1].joined = true
    for _ in 0 ..< 120:
      game.step()
    let before = game.world.standing()
    game.applyWallClockStop()
    check game.reason == erDeadline
    check game.endRule == erlWallClock
    check game.finalStanding.cityTiles == before.cityTiles
    check game.outcome.scoreOf(0) + game.outcome.scoreOf(1) == 1.0
    check game.stopDetail.len > 0

  test "elimination fires only at zero tiles AND zero units":
    var world = buildWorld()
    world.clearBoard()
    world.addCity(Red, 40)
    check not world.eliminated(0)
    check world.eliminated(1)
    discard world.addUnit(Blue, ukWorker, 200)
    check not world.eliminated(1)
