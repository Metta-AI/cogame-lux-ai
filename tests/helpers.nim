## Shared test helpers. Run every test from the repo ROOT: assets resolve via
## `data/`.

import std/[os, strutils]

import lux/sim

proc repoRoot*(): string =
  ## `tests/config.nims` puts `../src` on the path, and every test is run from
  ## the repo root by `ci.yml`, so the root is the current directory. Walk up
  ## if someone runs a test from inside `tests/`.
  result = getCurrentDir()
  for _ in 0 .. 3:
    if fileExists(result / "coworld_manifest_template.json"):
      return result
    result = result.parentDir()
  result = getCurrentDir()

proc readRepoFile*(path: string): string =
  readFile(repoRoot() / path)

proc fixtureConfig*(seed = 42, mapSize = 16): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.mapSize = mapSize
  result.lobbyJoinTimeoutTicks = 2
  result.startWaitTicks = 0

proc scriptedEpisode*(
  config: GameConfig, red = blForester, blue = blProspector
): SimServer =
  ## A whole scripted episode, directives refreshed on the real cadence.
  result = initSimServer(config)
  result.seats[0].joined = true
  result.seats[1].joined = true
  var lastDirective = -1
  while not result.episodeFinished():
    if result.phase == Playing and
        result.isDirectiveTurn(result.world.turn) and
        result.world.turn != lastDirective:
      lastDirective = result.world.turn
      result.setDirective(0, scriptedDirective(result.world, red, 0))
      result.setDirective(1, scriptedDirective(result.world, blue, 1))
    result.step()

proc buildWorld*(seed = 42, mapSize = 16): World =
  var config = defaultGameConfig()
  config.seed = seed
  config.mapSize = mapSize
  initWorld(config)

proc clearBoard*(world: var World) =
  ## An EMPTY island with no cities and no units: the base every ordered-rule
  ## case in test_lux_resolve builds its own tiny scenario on.
  for cell in 0 ..< world.board.cellCount():
    world.board.terrain[cell] = tEmpty
    world.board.amount[cell] = 0
    world.board.road[cell] = 0
  world.cities = initCities(world.board.cellCount())
  world.units = Units(nextId: 0)
  world.burntStack = newSeq[bool](world.board.cellCount())
  for seat in 0 .. 1:
    world.researchPoints[seat] = 0
    world.unitsBuilt[seat] = 0
    world.unitsLost[seat] = 0
    world.cityTilesBuilt[seat] = 0
    world.cityTilesLost[seat] = 0
    world.blockedMoves[seat] = 0

proc addCity*(world: var World, team: Team, cell: int, fuel: int64 = 0) =
  discard world.cities.addTile(world.board, team, cell)
  world.board.road[cell] = world.config.maxRoad
  let index = world.cities.indexOfCity(world.cities.cityOfCell[cell])
  world.cities.list[index].fuel = fuel

proc addUnit*(
  world: var World, team: Team, kind: UnitKind, cell: int,
  wood = 0, coal = 0, uranium = 0
): int {.discardable.} =
  result = world.units.spawn(team, kind, cell)
  let index = world.units.indexOfId(result)
  world.units.list[index].wood = wood
  world.units.list[index].coal = coal
  world.units.list[index].uranium = uranium

proc unitById*(world: World, id: int): Unit =
  let index = world.units.indexOfId(id)
  doAssert index >= 0, "no unit " & $id
  world.units.list[index]

proc hasUnit*(world: World, id: int): bool =
  world.units.indexOfId(id) >= 0

proc move*(unitId: int, dir: Direction): UnitAction =
  UnitAction(unitId: unitId, kind: uaMove, dir: dir)

proc center*(unitId: int): UnitAction =
  UnitAction(unitId: unitId, kind: uaCenter)

proc buildCity*(unitId: int): UnitAction =
  UnitAction(unitId: unitId, kind: uaBuildCity)

proc transfer*(
  unitId, receiverId: int, resource: Terrain, amount: int
): UnitAction =
  UnitAction(unitId: unitId, kind: uaTransfer, receiverId: receiverId,
    resource: resource, amount: amount)

proc countOccurrences*(text, needle: string): int =
  var at = 0
  while true:
    let found = text.find(needle, at)
    if found < 0:
      break
    inc result
    at = found + max(1, needle.len)
