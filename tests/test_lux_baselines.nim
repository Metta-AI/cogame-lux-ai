## Bounded orders on BOTH scripted baselines, plus the fallback-cannot-drift
## pin and the tuning pin.

import std/[json, random, unittest]

import lux/sim
import helpers

proc randomWorld(rng: var Rand, mapSize: int): World =
  var config = defaultGameConfig()
  config.seed = rng.rand(1 .. 2_000_000_000)
  config.mapSize = mapSize
  result = initWorld(config)
  result.eventLoggingEnabled = false
  result.turn = rng.rand(0 .. 359)
  for seat in 0 .. 1:
    result.researchPoints[seat] = rng.rand(0 .. 260)
  for _ in 0 ..< rng.rand(0 .. 14):
    let
      team = Team(rng.rand(0 .. 1))
      cell = rng.rand(0 ..< result.board.cellCount())
    if result.board.terrain[cell] == tEmpty and not result.cities.hasTile(cell):
      discard result.cities.addTile(result.board, team, cell)
      result.board.road[cell] = result.config.maxRoad
  for city in result.cities.list.mitems:
    city.fuel = int64(rng.rand(0 .. 6000))
  for _ in 0 ..< rng.rand(0 .. 18):
    let
      team = Team(rng.rand(0 .. 1))
      kind = if rng.rand(0 .. 3) == 0: ukCart else: ukWorker
      cell = rng.rand(0 ..< result.board.cellCount())
    if result.cities.teamOfCell[cell] in [-1, ord(team)]:
      var occupied = false
      for unit in result.units.list:
        if unit.cell == cell:
          occupied = true
      if not occupied or result.cities.teamOfCell[cell] == ord(team):
        let id = result.units.spawn(team, kind, cell)
        let index = result.units.indexOfId(id)
        result.units.list[index].wood = rng.rand(0 .. cargoCap(kind))
        result.units.list[index].cooldownTenths = rng.rand(0 .. 3) * 10
  for cell in 0 ..< result.board.cellCount():
    if result.board.terrain[cell] != tEmpty and rng.rand(0 .. 3) == 0:
      result.board.amount[cell] = 0

proc validates(directive: Directive, mapSize: int): bool =
  if directive.workers < 0 or directive.workers > MaxWorkers:
    return false
  if directive.carts < 0 or directive.carts > MaxCarts:
    return false
  if directive.hasFocus:
    if directive.focusX < 0 or directive.focusX >= mapSize:
      return false
    if directive.focusY < 0 or directive.focusY >= mapSize:
      return false
  var seen: array[3, bool]
  for kind in directive.mine:
    if kind == tEmpty:
      return false
    if seen[ord(kind) - 1]:
      return false
    seen[ord(kind) - 1] = true
  seen[0] and seen[1] and seen[2] and directive.note.len == 0

suite "lux baselines":
  test "both baselines are bounded over 300 pseudo-random worlds":
    var rng = initRand(20260827)
    for i in 0 ..< 300:
      let mapSize = if i mod 2 == 0: 16 else: 12
      var world = randomWorld(rng, mapSize)
      for baseline in [blForester, blProspector]:
        for seat in 0 .. 1:
          let directive = scriptedDirective(world, baseline, seat)
          checkpoint($baseline & " seat " & $seat & " world " & $i)
          check directive.validates(mapSize)
          ## and the SERIALISED structured directive fits the cap
          check ($directive.directiveJson()).len <= MaxDirectiveBytes
          check encodeDirective(directive).len == DirectiveBytes

  test "the emitted directive survives its own encode/decode round trip":
    var rng = initRand(7)
    for _ in 0 ..< 100:
      var world = randomWorld(rng, 16)
      for baseline in [blForester, blProspector]:
        let directive = scriptedDirective(world, baseline, 0)
        let round = decodeDirective(encodeDirective(directive))
        check round.stance == directive.stance
        check round.mine == directive.mine
        check round.research == directive.research
        check round.build == directive.build
        check round.workers == directive.workers
        check round.carts == directive.carts
        check round.hasFocus == directive.hasFocus
        check round.night == directive.night

  test "the fallback IS the forester proc, so the two cannot drift":
    var world = buildWorld(seed = 1734029581)
    for seat in 0 .. 1:
      check scriptedDirective(world, blForester, seat) ==
        foresterDirective(world, seat)
    check parseBaseline("forester") == blForester
    check parseBaseline("prospector") == blProspector
    check parseBaseline("nonsense") == blForester   ## the published default
    check parseBaseline("") == blForester

  test "forester beats prospector at the pinned seed, and both survive six nights":
    let game = scriptedEpisode(fixtureConfig(seed = 1734029581))
    check game.reason == erComplete
    check game.endRule == erlFullTime
    check game.finalStanding.cityTiles[0] > game.finalStanding.cityTiles[1]
    check game.world.nightsSurvived[0] >= 6
    check game.world.nightsSurvived[1] >= 6
    ## and it is a REAL game, not two dead islands
    check game.finalStanding.cityTiles[1] > 0
    check game.world.cityTilesBuilt[0] > 4
    check game.world.cityTilesBuilt[1] > 4

  test "the shipped tuning equals tools/ci/baseline_tuning.json":
    let stored = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))
    let shipped = defaultTuning()
    check shipped.foresterWorkers == stored["foresterWorkers"].getInt()
    check shipped.foresterFuelNights == stored["foresterFuelNights"].getInt()
    check shipped.prospectorEarlyWorkers ==
      stored["prospectorEarlyWorkers"].getInt()
    check shipped.prospectorLateWorkers ==
      stored["prospectorLateWorkers"].getInt()
    check shipped.prospectorSeedTiles == stored["prospectorSeedTiles"].getInt()
