## The micro layer: the deterministic compiler that turns ONE strategy
## directive into per-unit and per-tile actions, every single turn.
##
## Forked from coworld-ctf's `src/ctf/control.nim` (directive -> per-tick
## actuation), retargeted from pixel steering to Lux's discrete actions.
##
## It is a PURE FUNCTION of (world state, directive, seat) with no randomness
## and no network, it runs in microseconds, and THE BROWSER RUNS THE IDENTICAL
## NIM CODE — which is why the replay only has to carry 72 directives rather
## than a per-unit action log.
##
## The micro NEVER emits: a move off the board, a move onto an opponent city
## tile, a `build_city` on a resource tile or an occupied cell or under
## `cityCost` cargo, an action for a unit or tile with `cooldownTenths > 0`,
## more than one action for any unit or tile in a turn, or a `pillage`
## (pillage does not exist in v1). `tests/test_lux_micro.nim` asserts every one.
##
## PURE INTEGER — no floating point in this file.

import std/tables

import board, cities, directives, resolve, sim_state, sim_types, units

type
  MicroCache* = object
    ## Flow fields, cached per (team, goal cell) and recomputed at most once
    ## per turn per distinct goal.
    fields: Table[int, seq[int]]
    blocked: array[2, seq[bool]]
    turn: int
    ready: bool

proc reset*(cache: var MicroCache, world: World, turn: int) =
  cache.fields = initTable[int, seq[int]]()
  cache.turn = turn
  cache.ready = true
  for seat in 0 .. 1:
    cache.blocked[seat] = newSeq[bool](world.board.cellCount())
    for cell in 0 ..< world.board.cellCount():
      let tileTeam = world.cities.teamOfCell[cell]
      cache.blocked[seat][cell] = tileTeam >= 0 and tileTeam != seat

proc fieldFrom(
  cache: var MicroCache, world: World, seat, goal: int
): lent seq[int] =
  ## Distances from `goal` to every cell, for this seat's passability. BFS is
  ## symmetric on an undirected graph, so this doubles as "distance from any
  ## cell to the goal".
  let key = seat * 65536 + goal
  if not cache.fields.hasKey(key):
    cache.fields[key] =
      bfsDistances(world.board, [goal], cache.blocked[seat])
  cache.fields[key]

func friendlyTiles(world: World, seat: int): seq[int] =
  for cell in 0 ..< world.board.cellCount():
    if world.cities.teamOfCell[cell] == seat:
      result.add(cell)

proc nearestFriendlyTile(
  cache: var MicroCache, world: World, seat, fromCell: int
): int =
  ## Ties by lowest cell index — every tie-break in this file does.
  result = -1
  var best = high(int)
  let field = bfsDistances(world.board, [fromCell], cache.blocked[seat])
  for cell in 0 ..< world.board.cellCount():
    if world.cities.teamOfCell[cell] != seat:
      continue
    let distance = field[cell]
    if distance < 0:
      continue
    if distance < best:
      best = distance
      result = cell

proc stepToward(
  cache: var MicroCache, world: World, claimed: var seq[bool],
  seat, fromCell, goal: int
): UnitAction =
  ## The first move of the unique shortest path, or `center` when the unit is
  ## already there and when BFS finds no path at all (rule 5).
  ##
  ## CLAIMS. Step 6c of the turn structure CANCELS every mover onto a contested
  ## cell, and a cancelled move costs no cooldown — so two of a side's own units
  ## that keep choosing the same cell livelock forever, re-proposing the same
  ## cancelled move every turn. The micro therefore reserves each cell it has
  ## already routed a unit into (this seat's units only, in ascending unit id:
  ## the opponent's plan is not visible to this seat's compile and must not be)
  ## and takes the next-best shortest step instead, falling back to `center`,
  ## which reserves the unit's own cell. Deterministic, and it is what makes a
  ## column of workers file out of a city blob rather than jam in its doorway.
  if goal < 0 or goal == fromCell:
    claimed[fromCell] = true
    return UnitAction(kind: uaCenter)
  let field = cache.fieldFrom(world, seat, goal)
  if field[fromCell] < 0:
    claimed[fromCell] = true
    return UnitAction(kind: uaCenter)
  var
    bestIndex = -1
    bestDistance = field[fromCell]
  let
    x = world.board.cellX(fromCell)
    y = world.board.cellY(fromCell)
  for i in 0 ..< 4:
    let
      nx = x + StepDx[i]
      ny = y + StepDy[i]
    if not world.board.inside(nx, ny):
      continue
    let cell = ny * world.board.size + nx
    if field[cell] < 0 or field[cell] >= bestDistance:
      continue
    let friendlyTile = world.cities.teamOfCell[cell] == seat
    if claimed[cell] and not friendlyTile:
      continue
    bestDistance = field[cell]
    bestIndex = i
  if bestIndex < 0:
    claimed[fromCell] = true
    return UnitAction(kind: uaCenter)
  let target = (y + StepDy[bestIndex]) * world.board.size + x + StepDx[bestIndex]
  claimed[target] = true
  UnitAction(kind: uaMove, dir: stepDirection(bestIndex))

func isAdjacentOrOn(world: World, cell, target: int): bool =
  if cell == target:
    return true
  for neighbour in world.board.orthogonal(target):
    if neighbour == cell:
      return true
  false

proc buildTarget(
  cache: var MicroCache, world: World, directive: Directive,
  seat, fromCell: int
): int =
  ## `expand`: the empty, city-tile-free cell minimising
  ## `bfs(worker, cell) + 2 * chebyshev(cell, focus)` among cells orthogonally
  ## adjacent to one of this side's city tiles if any lies within
  ## `buildRadius`; otherwise among cells adjacent to any resource tile.
  ## Preferring a cell that TOUCHES an existing tile is what makes the 5-fuel
  ## adjacency discount happen without the LLM having to micro it.
  ##
  ## `contest`: the same, but the candidate set is cells adjacent to the
  ## resource tile NEAREST the opponent's nearest city tile.
  let field = bfsDistances(world.board, [fromCell], cache.blocked[seat])
  var candidates: seq[int] = @[]

  proc emptyBuildable(cell: int): bool =
    world.board.terrain[cell] == tEmpty and not world.cities.hasTile(cell) and
      field[cell] >= 0

  if directive.stance == stContest:
    var
      anchor = -1
      bestDistance = high(int)
    let opponentTiles = friendlyTiles(world, 1 - seat)
    if opponentTiles.len > 0:
      let toOpponent =
        bfsDistances(world.board, opponentTiles, cache.blocked[seat])
      for cell in 0 ..< world.board.cellCount():
        if world.board.terrain[cell] == tEmpty or world.board.amount[cell] <= 0:
          continue
        let distance = toOpponent[cell]
        if distance < 0:
          continue
        if distance < bestDistance:
          bestDistance = distance
          anchor = cell
    if anchor >= 0:
      for neighbour in world.board.orthogonal(anchor):
        if emptyBuildable(neighbour):
          candidates.add(neighbour)
  if candidates.len == 0:
    for cell in 0 ..< world.board.cellCount():
      if world.cities.teamOfCell[cell] != seat:
        continue
      for neighbour in world.board.orthogonal(cell):
        if emptyBuildable(neighbour) and field[neighbour] <= BuildRadius and
            neighbour notin candidates:
          candidates.add(neighbour)
  if candidates.len == 0:
    for cell in 0 ..< world.board.cellCount():
      if world.board.terrain[cell] == tEmpty or world.board.amount[cell] <= 0:
        continue
      for neighbour in world.board.orthogonal(cell):
        if emptyBuildable(neighbour) and neighbour notin candidates:
          candidates.add(neighbour)
  if candidates.len == 0:
    return -1
  result = -1
  var best = high(int)
  for cell in candidates:
    var cost = field[cell]
    if directive.hasFocus:
      cost += 2 * chebyshev(world.board.cellX(cell), world.board.cellY(cell),
        directive.focusX, directive.focusY)
    if cost < best:
      best = cost
      result = cell

proc mineTarget(
  cache: var MicroCache, world: World, directive: Directive,
  seat, fromCell: int, assigned: Table[int, int]
): int =
  ## Over the kinds in `directive.mine` ORDER, the first kind the team has
  ## researched and that has a tile with `amount > 0`; among that kind's tiles,
  ## minimise `bfs(worker, tile) + 2 * (workers already assigned to it this
  ## turn)`. The congestion term is what spreads six workers over a wood
  ## cluster instead of stacking them on one square.
  let field = bfsDistances(world.board, [fromCell], cache.blocked[seat])
  for kind in directive.mine:
    let gate = (case kind
                of tCoal: world.config.coalResearch
                of tUranium: world.config.uraniumResearch
                else: 0)
    if world.researchPoints[seat] < gate:
      continue
    var
      best = -1
      bestCost = high(int)
    for cell in 0 ..< world.board.cellCount():
      if world.board.terrain[cell] != kind or world.board.amount[cell] <= 0:
        continue
      if field[cell] < 0:
        continue
      var cost = field[cell] + 2 * assigned.getOrDefault(cell, 0)
      if cost < bestCost:
        bestCost = cost
        best = cell
    if best >= 0:
      return best
  -1

proc compileTurn*(
  cache: var MicroCache, world: World, directive: Directive, seat: int
): TurnOrders =
  ## At most ONE action per unit whose `cooldownTenths == 0` and at most one
  ## action per city tile whose `cooldownTenths == 0`. Pure: the same
  ## (state, directive, seat) triple yields the identical action list on every
  ## call, natively and in wasm.
  if not cache.ready or cache.turn != world.turn:
    cache.reset(world, world.turn)
  let
    team = Team(seat)
    night = world.isNight(world.turn)
  var
    assigned = initTable[int, int]()
    claimed = newSeq[bool](world.board.cellCount())
  for unit in world.units.list:
    ## A unit that cannot act this turn is furniture: it holds its cell.
    if ord(unit.team) == seat and unit.cooldownTenths != 0:
      claimed[unit.cell] = true

  # ---- units, ascending id -------------------------------------------------
  for index in 0 ..< world.units.list.len:
    let unit = world.units.list[index]
    if ord(unit.team) != seat or unit.cooldownTenths != 0:
      continue

    if unit.kind == ukCart:
      # A cart hauls: home when loaded, otherwise to the loaded worker that is
      # furthest from home. That is the cart's entire job.
      if unit.totalCargo() > 0:
        let home = cache.nearestFriendlyTile(world, seat, unit.cell)
        var action = cache.stepToward(world, claimed, seat, unit.cell, home)
        action.unitId = unit.id
        result.unitActions.add(action)
        continue
      var
        pick = -1
        pickCargo = -1
      for other in world.units.list:
        if ord(other.team) != seat or other.kind != ukWorker:
          continue
        let home = cache.nearestFriendlyTile(world, seat, other.cell)
        if home >= 0:
          let field = cache.fieldFrom(world, seat, home)
          if field[other.cell] >= 0 and field[other.cell] < 4:
            continue
        if other.totalCargo() > pickCargo:
          pickCargo = other.totalCargo()
          pick = other.cell
      if pick < 0 or isAdjacentOrOn(world, unit.cell, pick):
        claimed[unit.cell] = true
        result.unitActions.add(UnitAction(unitId: unit.id, kind: uaCenter))
      else:
        var action = cache.stepToward(world, claimed, seat, unit.cell, pick)
        action.unitId = unit.id
        result.unitActions.add(action)
      continue

    # ---- workers ----------------------------------------------------------
    var stance = directive.stance
    if night and directive.night == npHaul:
      stance = stFuel

    # Rule 4, evaluated BEFORE rules 2 and 3: hand off to an adjacent cart.
    block handoff:
      if unit.totalCargo() < 40:
        break handoff
      let home = cache.nearestFriendlyTile(world, seat, unit.cell)
      if home >= 0:
        let field = cache.fieldFrom(world, seat, home)
        if field[unit.cell] >= 0 and field[unit.cell] <= 4:
          break handoff
      var
        cartId = -1
        cartCell = -1
      for other in world.units.list:
        if ord(other.team) != seat or other.kind != ukCart:
          continue
        if other.freeCargo(cargoCap(world, ukCart)) <= 0:
          continue
        var adjacent = false
        for neighbour in world.board.orthogonal(unit.cell):
          if neighbour == other.cell:
            adjacent = true
            break
        if adjacent and (cartId < 0 or other.id < cartId):
          cartId = other.id
          cartCell = other.cell
      if cartId < 0:
        break handoff
      discard cartCell
      var kind = tWood
      if unit.coal >= unit.wood and unit.coal >= unit.uranium: kind = tCoal
      if unit.uranium > unit.wood and unit.uranium > unit.coal: kind = tUranium
      if unit.wood >= unit.coal and unit.wood >= unit.uranium: kind = tWood
      claimed[unit.cell] = true
      result.unitActions.add(UnitAction(
        unitId: unit.id, kind: uaTransfer, receiverId: cartId,
        resource: kind, amount: unit.stockOf(kind)))
      continue

    # Rule 1: the night policy.
    if night and directive.night == npShelter:
      if world.cities.teamOfCell[unit.cell] == seat:
        claimed[unit.cell] = true
        result.unitActions.add(UnitAction(unitId: unit.id, kind: uaCenter))
        continue
      let home = cache.nearestFriendlyTile(world, seat, unit.cell)
      if home >= 0:
        var action = cache.stepToward(world, claimed, seat, unit.cell, home)
        action.unitId = unit.id
        result.unitActions.add(action)
        continue

    # Rule 2: full or nearly full.
    if unit.totalCargo() >= world.config.cityCost:
      if stance in {stExpand, stContest} or directive.build == boCity:
        let goal = cache.buildTarget(world, directive, seat, unit.cell)
        if goal == unit.cell:
          claimed[unit.cell] = true
          result.unitActions.add(UnitAction(unitId: unit.id, kind: uaBuildCity))
        else:
          var action = cache.stepToward(world, claimed, seat, unit.cell, goal)
          action.unitId = unit.id
          result.unitActions.add(action)
        continue
      var goal = -1
      if stance == stTurtle:
        let largest = world.cities.largestCityIndex(team)
        if largest >= 0:
          goal = world.cities.list[largest].cells[0]
      if goal < 0:
        goal = cache.nearestFriendlyTile(world, seat, unit.cell)
      var action = cache.stepToward(world, claimed, seat, unit.cell, goal)
      action.unitId = unit.id
      result.unitActions.add(action)
      continue

    # Rule 3: mining.
    let target = cache.mineTarget(world, directive, seat, unit.cell, assigned)
    if target < 0:
      claimed[unit.cell] = true
      result.unitActions.add(UnitAction(unitId: unit.id, kind: uaCenter))
      continue
    assigned[target] = assigned.getOrDefault(target, 0) + 1
    if isAdjacentOrOn(world, unit.cell, target):
      claimed[unit.cell] = true
      result.unitActions.add(UnitAction(unitId: unit.id, kind: uaCenter))
    else:
      var action = cache.stepToward(world, claimed, seat, unit.cell, target)
      action.unitId = unit.id
      result.unitActions.add(action)

  # ---- city tiles, ascending tile index -----------------------------------
  let
    researchTarget = (case directive.research
                      of rtNone: 0
                      of rtCoal: world.config.coalResearch
                      of rtUranium, rtAlways: world.config.uraniumResearch)
    tileTotal = world.cities.tileCount(team)
  var
    unitTotal = world.units.countOf(team)
    workerTotal = world.units.countOf(team, ukWorker)
    cartTotal = world.units.countOf(team, ukCart)
  for cell in 0 ..< world.board.cellCount():
    if world.cities.teamOfCell[cell] != seat:
      continue
    if world.cities.cooldownOfCell[cell] != 0:
      continue
    if directive.build == boCity:
      continue                       ## the tile idles; workers do the building
    # PRODUCTION BEFORE RESEARCH. The design note orders research first, but
    # S1's unit cap (`units < cityTiles`) makes that self-defeating at the
    # opening: a side with one tile and one worker would spend every tile
    # action of the first hundred turns on research points and starve, because
    # a research point does not mine wood and the night bill does not wait.
    # Research therefore YIELDS while the side is BOTH under the unit cap and
    # below its directive's unit target — which is exactly the trade the system
    # prompt describes to the model ("a city tile spends its whole turn to earn
    # ONE research point, so research costs you workers"). Documented in
    # docs/RULES.md as the one amendment to the note's rule order.
    let headroom = unitTotal < tileTotal
    if headroom and directive.build == boWorker:
      result.tileActions.add(TileAction(cell: cell, kind: taBuildWorker))
      inc unitTotal
      inc workerTotal
      continue
    if headroom and directive.build == boCart:
      result.tileActions.add(TileAction(cell: cell, kind: taBuildCart))
      inc unitTotal
      inc cartTotal
      continue
    if headroom and cartTotal < directive.carts:
      result.tileActions.add(TileAction(cell: cell, kind: taBuildCart))
      inc unitTotal
      inc cartTotal
      continue
    if headroom and workerTotal < directive.workers:
      result.tileActions.add(TileAction(cell: cell, kind: taBuildWorker))
      inc unitTotal
      inc workerTotal
      continue
    if directive.research == rtAlways or
        world.researchPoints[seat] < researchTarget:
      result.tileActions.add(TileAction(cell: cell, kind: taResearch))

proc compileBothSeats*(
  cache: var MicroCache, world: World, directives: array[2, Directive]
): TurnOrders =
  ## Seat 0 then seat 1 — the order step 2 of the turn structure fixes.
  cache.reset(world, world.turn)
  for seat in 0 .. 1:
    let orders = cache.compileTurn(world, directives[seat], seat)
    for action in orders.unitActions:
      result.unitActions.add(action)
    for action in orders.tileActions:
      result.tileActions.add(action)
