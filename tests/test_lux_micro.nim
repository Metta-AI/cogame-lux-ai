## The micro layer never emits an illegal action, and it is a pure function.

import std/[random, sets, tables, unittest]

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
  for _ in 0 ..< rng.rand(0 .. 12):
    let
      team = Team(rng.rand(0 .. 1))
      cell = rng.rand(0 ..< result.board.cellCount())
    if result.board.terrain[cell] == tEmpty and not result.cities.hasTile(cell):
      discard result.cities.addTile(result.board, team, cell)
      result.board.road[cell] = result.config.maxRoad
  for city in result.cities.list.mitems:
    city.fuel = int64(rng.rand(0 .. 6000))
  var occupied: HashSet[int]
  for _ in 0 ..< rng.rand(0 .. 16):
    let
      team = Team(rng.rand(0 .. 1))
      kind = if rng.rand(0 .. 3) == 0: ukCart else: ukWorker
      cell = rng.rand(0 ..< result.board.cellCount())
    if cell in occupied:
      continue
    if result.cities.teamOfCell[cell] notin [-1, ord(team)]:
      continue
    occupied.incl(cell)
    let id = result.units.spawn(team, kind, cell)
    let index = result.units.indexOfId(id)
    result.units.list[index].wood = rng.rand(0 .. cargoCap(kind))
    result.units.list[index].cooldownTenths = rng.rand(0 .. 3) * 10

proc randomDirective(rng: var Rand, mapSize: int): Directive =
  result = defaultDirective()
  result.stance = Stance(rng.rand(0 .. ord(high(Stance))))
  result.research = ResearchTarget(rng.rand(0 .. ord(high(ResearchTarget))))
  result.build = BuildOrder(rng.rand(0 .. ord(high(BuildOrder))))
  result.night = NightPolicy(rng.rand(0 .. ord(high(NightPolicy))))
  result.workers = rng.rand(0 .. MaxWorkers)
  result.carts = rng.rand(0 .. MaxCarts)
  result.hasFocus = rng.rand(0 .. 2) > 0
  result.focusX = rng.rand(0 ..< mapSize)
  result.focusY = rng.rand(0 ..< mapSize)
  var kinds = @[tWood, tCoal, tUranium]
  rng.shuffle(kinds)
  for i in 0 .. 2:
    result.mine[i] = kinds[i]

proc assertLegal(world: World, orders: TurnOrders, seat: int) =
  var
    seenUnits: HashSet[int]
    seenTiles: HashSet[int]
    actedOn: HashSet[int]
  for action in orders.unitActions:
    check action.unitId notin seenUnits    ## at most one action per unit
    seenUnits.incl(action.unitId)
    let index = world.units.indexOfId(action.unitId)
    check index >= 0
    let unit = world.units.list[index]
    check ord(unit.team) == seat
    check unit.cooldownTenths == 0         ## never for a cooling unit
    actedOn.incl(action.unitId)
    case action.kind
    of uaNone:
      check false                          ## every action is explicit
    of uaCenter:
      discard
    of uaMove:
      check action.dir != dCenter
      let step = directionIndex(action.dir)
      let
        nx = world.board.cellX(unit.cell) + StepDx[step]
        ny = world.board.cellY(unit.cell) + StepDy[step]
      check world.board.inside(nx, ny)     ## never off the board
      let target = ny * world.board.size + nx
      let tileTeam = world.cities.teamOfCell[target]
      check tileTeam in [-1, seat]         ## never onto an opponent city tile
    of uaTransfer:
      let receiver = world.units.indexOfId(action.receiverId)
      check receiver >= 0
      check ord(world.units.list[receiver].team) == seat
      check action.amount > 0
    of uaBuildCity:
      check unit.kind == ukWorker
      check world.board.terrain[unit.cell] == tEmpty
      check not world.cities.hasTile(unit.cell)
      check unit.totalCargo() >= world.config.cityCost
  for action in orders.tileActions:
    check action.cell notin seenTiles      ## at most one action per tile
    seenTiles.incl(action.cell)
    check world.cities.teamOfCell[action.cell] == seat
    check world.cities.cooldownOfCell[action.cell] == 0
    check action.kind != taNone
  ## no unit of this seat is left with no decision
  for unit in world.units.list:
    if ord(unit.team) == seat and unit.cooldownTenths == 0:
      check unit.id in actedOn

suite "lux micro":
  test "the micro never emits an illegal action, over both baselines":
    var rng = initRand(20260827)
    var cache: MicroCache
    for i in 0 ..< 300:
      let mapSize = if i mod 2 == 0: 16 else: 12
      var world = randomWorld(rng, mapSize)
      for baseline in [blForester, blProspector]:
        for seat in 0 .. 1:
          let directive = scriptedDirective(world, baseline, seat)
          cache.reset(world, world.turn)
          let orders = cache.compileTurn(world, directive, seat)
          checkpoint($baseline & " seat " & $seat & " world " & $i)
          world.assertLegal(orders, seat)

  test "the micro never emits an illegal action, over 200 random valid directives":
    var rng = initRand(4242)
    var cache: MicroCache
    for i in 0 ..< 200:
      let mapSize = if i mod 3 == 0: 12 else: 16
      var world = randomWorld(rng, mapSize)
      let directive = randomDirective(rng, mapSize)
      for seat in 0 .. 1:
        cache.reset(world, world.turn)
        let orders = cache.compileTurn(world, directive, seat)
        checkpoint("directive world " & $i & " seat " & $seat)
        world.assertLegal(orders, seat)

  test "the micro is a pure function of (state, directive, seat)":
    var rng = initRand(99)
    var cache: MicroCache
    for _ in 0 ..< 60:
      var world = randomWorld(rng, 16)
      let directive = randomDirective(rng, 16)
      cache.reset(world, world.turn)
      let first = cache.compileTurn(world, directive, 0)
      var fresh: MicroCache
      fresh.reset(world, world.turn)
      let second = fresh.compileTurn(world, directive, 0)
      check first.unitActions == second.unitActions
      check first.tileActions == second.tileActions
      ## and a warm cache must agree with a cold one
      let third = cache.compileTurn(world, directive, 0)
      check third.unitActions == first.unitActions

  test "no action a whole scripted episode emits is ever illegal":
    var config = fixtureConfig(seed = 1734029581)
    var world = initWorld(config)
    world.eventLoggingEnabled = false
    var cache: MicroCache
    var directives: array[2, Directive]
    for turn in 0 ..< config.maxTurns:
      world.turn = turn
      if turn mod config.directiveEvery == 0:
        directives[0] = scriptedDirective(world, blForester, 0)
        directives[1] = scriptedDirective(world, blProspector, 1)
      cache.reset(world, turn)
      for seat in 0 .. 1:
        world.assertLegal(cache.compileTurn(world, directives[seat], seat), seat)
      world.resolveTurn(cache.compileBothSeats(world, directives), turn)
      world.checkLuxInvariants()
