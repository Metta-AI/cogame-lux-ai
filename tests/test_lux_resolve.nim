## The ordered rules, one case per numbered step of the turn structure.

import std/[random, unittest]

import lux/sim
import helpers

proc step(world: var World, orders: TurnOrders, turn = 0) =
  world.turn = turn
  world.resolveTurn(orders, turn)

suite "lux resolve":
  test "research gates":
    var world = buildWorld()
    world.clearBoard()
    world.board.terrain[20] = tCoal
    world.board.amount[20] = 400
    let worker = world.addUnit(Red, ukWorker, 21)
    world.researchPoints[0] = 49
    world.step(TurnOrders())
    check world.unitById(worker).coal == 0
    world.researchPoints[0] = 50
    world.step(TurnOrders())
    check world.unitById(worker).coal == 5

    world.clearBoard()
    world.board.terrain[20] = tUranium
    world.board.amount[20] = 325
    let miner = world.addUnit(Red, ukWorker, 21)
    world.researchPoints[0] = 199
    world.step(TurnOrders())
    check world.unitById(miner).uranium == 0
    world.researchPoints[0] = 200
    world.step(TurnOrders())
    check world.unitById(miner).uranium == 2

  test "collection split":
    var world = buildWorld()
    world.clearBoard()
    world.board.terrain[20] = tWood
    world.board.amount[20] = 40
    let
      a = world.addUnit(Red, ukWorker, 19)
      b = world.addUnit(Red, ukWorker, 21)
      c = world.addUnit(Red, ukWorker, 4)     ## 20 - 16, i.e. straight above
    world.step(TurnOrders())
    check [world.unitById(a).wood, world.unitById(b).wood,
           world.unitById(c).wood] == [14, 13, 13]
    check world.board.amount[20] == 0

  test "a nearly full worker takes only what fits, and a cart takes nothing":
    var world = buildWorld()
    world.clearBoard()
    world.board.terrain[20] = tWood
    world.board.amount[20] = 300
    let worker = world.addUnit(Red, ukWorker, 21, wood = 95)
    world.step(TurnOrders())
    check world.unitById(worker).wood == 100
    check world.board.amount[20] == 295 + max(1, 295 div 50)

    world.clearBoard()
    world.board.terrain[20] = tWood
    world.board.amount[20] = 300
    let cart = world.addUnit(Red, ukCart, 21)
    world.step(TurnOrders())
    check world.unitById(cart).totalCargo() == 0

  test "collection order is wood, then coal, then uranium, and never over cap":
    var world = buildWorld()
    world.clearBoard()
    world.board.terrain[19] = tWood
    world.board.amount[19] = 300
    world.board.terrain[21] = tCoal
    world.board.amount[21] = 400
    world.board.terrain[4] = tUranium
    world.board.amount[4] = 325
    world.researchPoints[0] = 200
    let worker = world.addUnit(Red, ukWorker, 20)
    world.step(TurnOrders())
    let after = world.unitById(worker)
    check after.wood == 20
    check after.coal == 5
    check after.uranium == 2
    check after.totalCargo() <= WorkerCargo

  test "deposit happens every turn, day and night, at 1/10/40":
    var world = buildWorld()
    world.clearBoard()
    world.addCity(Red, 20, fuel = 0)
    let worker = world.addUnit(Red, ukWorker, 20, wood = 3, coal = 2, uranium = 1)
    world.step(TurnOrders())
    check world.cities.list[0].fuel == 3 * 1 + 2 * 10 + 1 * 40
    check world.unitById(worker).totalCargo() == 0

  test "build city: refused on resource, on a tile, and at 99; accepted at 100":
    var world = buildWorld()
    world.clearBoard()
    world.board.terrain[20] = tWood
    world.board.amount[20] = 300
    let onResource = world.addUnit(Red, ukWorker, 20, wood = 100)
    world.step(TurnOrders(unitActions: @[buildCity(onResource)]))
    check not world.cities.hasTile(20)

    world.clearBoard()
    world.addCity(Blue, 30)
    let onTile = world.addUnit(Red, ukWorker, 40, wood = 99)
    world.step(TurnOrders(unitActions: @[buildCity(onTile)]))
    check not world.cities.hasTile(40)

    world.clearBoard()
    let rich = world.addUnit(Red, ukWorker, 40, wood = 100)
    world.step(TurnOrders(unitActions: @[buildCity(rich)]))
    check world.cities.hasTile(40)
    check world.cities.teamOfCell[40] == 0
    check world.unitById(rich).totalCargo() == 0
    check world.board.road[40] == world.config.maxRoad

  test "build city spends wood before coal before uranium":
    var world = buildWorld()
    world.clearBoard()
    let worker = world.addUnit(Red, ukWorker, 40, wood = 60, coal = 30, uranium = 30)
    world.step(TurnOrders(unitActions: @[buildCity(worker)]))
    let after = world.unitById(worker)
    check after.wood == 0
    check after.coal == 0
    ## The build spent 60 wood + 30 coal + 10 uranium; step 8 then DEPOSITED
    ## the 20 uranium it was still carrying into the city it had just built,
    ## because deposit runs every turn for every unit on a friendly tile.
    check after.uranium == 0
    check world.cities.list[0].fuel == 20 * UraniumFuel

  test "a contested build: both sides fail and neither spends":
    var world = buildWorld()
    world.clearBoard()
    let
      red = world.addUnit(Red, ukWorker, 40, wood = 100)
      blue = world.addUnit(Blue, ukWorker, 40, wood = 100)
    world.burntStack[40] = true    ## the only way two teams share a cell
    world.step(TurnOrders(unitActions: @[buildCity(red), buildCity(blue)]))
    check not world.cities.hasTile(40)
    check world.unitById(red).wood == 100
    check world.unitById(blue).wood == 100

  test "two friendly builders on one cell: the lower unit id builds":
    var world = buildWorld()
    world.clearBoard()
    let
      first = world.addUnit(Red, ukWorker, 40, wood = 100)
      second = world.addUnit(Red, ukWorker, 40, wood = 100)
    world.burntStack[40] = true
    world.step(TurnOrders(unitActions: @[buildCity(first), buildCity(second)]))
    check world.cities.hasTile(40)
    check world.cityTilesBuilt[0] == 1
    ## The loser's action was DISCARDED, so it spent nothing on the build — but
    ## it is now standing on a friendly city tile, so step 8 banks its cargo.
    check world.unitById(second).wood == 0
    check world.cities.list[0].fuel == 100 * WoodFuel

  test "merge: a tile between two cities merges them into the lowest id":
    var world = buildWorld()
    world.clearBoard()
    world.addCity(Red, 40, fuel = 100)
    world.addCity(Red, 42, fuel = 250)
    check world.cities.list.len == 2
    let worker = world.addUnit(Red, ukWorker, 41, wood = 100)
    world.step(TurnOrders(unitActions: @[buildCity(worker)]))
    check world.cities.list.len == 1
    check world.cities.list[0].id == 0
    check world.cities.list[0].fuel == 350
    check world.cities.list[0].cells.len == 3

  test "movement: off-map and enemy-city targets are discarded at no cooldown":
    var world = buildWorld()
    world.clearBoard()
    let edge = world.addUnit(Red, ukWorker, 0)
    world.step(TurnOrders(unitActions: @[move(edge, dNorth)]))
    check world.unitById(edge).cell == 0
    check world.unitById(edge).cooldownTenths == 0

    world.clearBoard()
    world.addCity(Blue, 41)
    let blocked = world.addUnit(Red, ukWorker, 40)
    world.step(TurnOrders(unitActions: @[move(blocked, dEast)]))
    check world.unitById(blocked).cell == 40
    check world.unitById(blocked).cooldownTenths == 0

  test "movement: a stationary unit blocks, and a column behind a mover advances":
    var world = buildWorld()
    world.clearBoard()
    let
      stuck = world.addUnit(Red, ukWorker, 41)
      behind = world.addUnit(Red, ukWorker, 40)
    world.step(TurnOrders(unitActions: @[move(behind, dEast)]))
    check world.unitById(behind).cell == 40
    check world.blockedMoves[0] == 1

    world.clearBoard()
    let
      lead = world.addUnit(Red, ukWorker, 42)
      middle = world.addUnit(Red, ukWorker, 41)
      tail = world.addUnit(Red, ukWorker, 40)
    world.step(TurnOrders(unitActions: @[
      move(lead, dEast), move(middle, dEast), move(tail, dEast)]))
    check world.unitById(lead).cell == 43
    check world.unitById(middle).cell == 42
    check world.unitById(tail).cell == 41
    discard stuck

  test "movement: two units onto one empty cell both stay; two adjacent units swap":
    var world = buildWorld()
    world.clearBoard()
    let
      west = world.addUnit(Red, ukWorker, 40)
      east = world.addUnit(Red, ukWorker, 42)
    world.step(TurnOrders(unitActions: @[move(west, dEast), move(east, dWest)]))
    check world.unitById(west).cell == 40
    check world.unitById(east).cell == 42

    world.clearBoard()
    let
      a = world.addUnit(Red, ukWorker, 40)
      b = world.addUnit(Red, ukWorker, 41)
    world.step(TurnOrders(unitActions: @[move(a, dEast), move(b, dWest)]))
    check world.unitById(a).cell == 41
    check world.unitById(b).cell == 40

  test "any number of friendly units stack on a friendly city tile":
    var world = buildWorld()
    world.clearBoard()
    world.addCity(Red, 41)
    let
      a = world.addUnit(Red, ukWorker, 40)
      b = world.addUnit(Red, ukWorker, 42)
      c = world.addUnit(Red, ukWorker, 25)
    world.step(TurnOrders(unitActions: @[
      move(a, dEast), move(b, dWest), move(c, dSouth)]))
    check world.unitById(a).cell == 41
    check world.unitById(b).cell == 41
    check world.unitById(c).cell == 41

  test "the movement fixed point is order-independent":
    ## Shuffle the ACTION order and the outcome must not move.
    var reference: seq[int]
    for attempt in 0 .. 24:
      var world = buildWorld()
      world.clearBoard()
      var ids: seq[int]
      for i in 0 .. 5:
        ids.add(world.addUnit(Red, ukWorker, 40 + i))
      var actions: seq[UnitAction]
      for i, id in ids:
        actions.add(move(id, if i mod 2 == 0: dEast else: dSouth))
      var rng = initRand(attempt + 1)
      rng.shuffle(actions)
      world.step(TurnOrders(unitActions: actions))
      var cells: seq[int]
      for id in ids:
        cells.add(world.unitById(id).cell)
      if attempt == 0:
        reference = cells
      else:
        check cells == reference

  test "night: a 6-tile line pays 113 and a 3x3 blob of 9 pays 147":
    var world = buildWorld()
    world.clearBoard()
    for i in 0 .. 5:
      world.addCity(Red, 40 + i, fuel = 10_000)
    check world.cities.list[0].upkeep(world.board, 23, 5) == 23 * 6 - 5 * 5

    world.clearBoard()
    for row in 0 .. 2:
      for col in 0 .. 2:
        world.addCity(Red, (3 + row) * world.board.size + 3 + col, fuel = 10_000)
    check world.cities.list[0].cells.len == 9
    check world.cities.list[0].upkeep(world.board, 23, 5) == 23 * 9 - 5 * 12

  test "night: a city one fuel short is destroyed entirely, all tiles at once":
    var world = buildWorld()
    world.clearBoard()
    for row in 0 .. 2:
      for col in 0 .. 2:
        world.addCity(Red, (3 + row) * world.board.size + 3 + col)
    world.cities.list[0].fuel = 146
    world.step(TurnOrders(), turn = 30)
    check world.cities.list.len == 0
    check world.cityTilesLost[0] == 9
    world.cities = initCities(world.board.cellCount())

  test "night: units outside pay 4, inside pay nothing, and a destroyed city saves nobody":
    var world = buildWorld()
    world.clearBoard()
    let
      dies = world.addUnit(Red, ukWorker, 100, wood = 3)
      lives = world.addUnit(Red, ukWorker, 120, wood = 4)
      coal = world.addUnit(Red, ukWorker, 140, coal = 1)
    world.addCity(Red, 200, fuel = 10_000)
    let sheltered = world.addUnit(Red, ukWorker, 200, wood = 0)
    world.step(TurnOrders(), turn = 30)
    check not world.hasUnit(dies)
    check world.hasUnit(lives)
    check world.unitById(lives).wood == 0
    check world.hasUnit(coal)
    check world.unitById(coal).coal == 0
    check world.hasUnit(sheltered)
    check world.unitsLost[0] == 1

    world.clearBoard()
    world.addCity(Red, 200, fuel = 0)
    let doomed = world.addUnit(Red, ukWorker, 200)
    world.step(TurnOrders(), turn = 30)
    check not world.hasUnit(doomed)   ## the city burned first; it pays its own

  test "cooldown and roads":
    var world = buildWorld()
    world.clearBoard()
    let slow = world.addUnit(Red, ukWorker, 40)
    world.step(TurnOrders(unitActions: @[move(slow, dEast)]))
    check world.unitById(slow).cooldownTenths == 10   ## 20 spent, 10 recovered
    world.step(TurnOrders(unitActions: @[move(slow, dEast)]))
    check world.unitById(slow).cell == 41             ## refused: still cooling
    check world.unitById(slow).cooldownTenths == 0

    world.clearBoard()
    world.board.road[40] = 6
    world.board.road[41] = 6
    let fast = world.addUnit(Red, ukWorker, 40)
    world.step(TurnOrders(unitActions: @[move(fast, dEast)]))
    check world.unitById(fast).cooldownTenths == 0    ## 20 spent, 22 recovered

  test "a cart paves, capped at 6, and never on a resource tile":
    var world = buildWorld()
    world.clearBoard()
    let cart = world.addUnit(Red, ukCart, 40)
    world.step(TurnOrders(unitActions: @[move(cart, dEast)]))
    check world.board.road[41] == 1
    world.board.terrain[42] = tWood
    world.board.amount[42] = 300
    world.units.list[0].cooldownTenths = 0
    world.step(TurnOrders(unitActions: @[move(cart, dEast)]))
    check world.board.road[42] == 0

  test "the unit cap refuses a build at units == cityTiles and accepts one tile later":
    var world = buildWorld()
    world.clearBoard()
    world.addCity(Red, 40, fuel = 10_000)
    discard world.addUnit(Red, ukWorker, 40)
    world.step(TurnOrders(tileActions: @[TileAction(cell: 40, kind: taBuildWorker)]))
    check world.units.countOf(Red) == 1
    world.addCity(Red, 41, fuel = 10_000)
    world.cities.cooldownOfCell[40] = 0
    world.step(TurnOrders(tileActions: @[TileAction(cell: 40, kind: taBuildWorker)]))
    check world.units.countOf(Red) == 2

  test "wood regrowth: 300 -> 306 -> 312, zero stays zero, nothing exceeds 500":
    var world = buildWorld()
    world.clearBoard()
    world.board.terrain[40] = tWood
    world.board.amount[40] = 300
    world.board.terrain[41] = tWood
    world.board.amount[41] = 0
    world.board.terrain[42] = tWood
    world.board.amount[42] = 499
    world.step(TurnOrders())
    check world.board.amount[40] == 306
    check world.board.amount[41] == 0
    check world.board.amount[42] == 500
    world.step(TurnOrders())
    check world.board.amount[40] == 312
    check world.board.amount[41] == 0
    check world.board.amount[42] == 500

  test "transfers move at most the giver's stock and the receiver's free space":
    var world = buildWorld()
    world.clearBoard()
    let
      giver = world.addUnit(Red, ukWorker, 40, wood = 60)
      cart = world.addUnit(Red, ukCart, 41)
      far = world.addUnit(Red, ukWorker, 200)
    world.step(TurnOrders(unitActions: @[transfer(giver, cart, tWood, 900)]))
    check world.unitById(giver).wood == 0
    check world.unitById(cart).wood == 60
    world.units.list[world.units.indexOfId(giver)].cooldownTenths = 0
    world.units.list[world.units.indexOfId(giver)].wood = 10
    world.step(TurnOrders(unitActions: @[transfer(giver, far, tWood, 10)]))
    check world.unitById(giver).wood == 10     ## not adjacent: discarded
