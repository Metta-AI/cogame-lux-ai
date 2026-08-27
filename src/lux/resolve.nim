## Steps 3-11 of the design note's turn structure, in that exact order,
## including the movement fixed point and the collection split.
##
## An action that is ILLEGAL at the moment it is evaluated is DISCARDED and
## costs no cooldown — the starter's repair-don't-punish discipline, applied to
## the sim.
##
## PURE INTEGER — no floating point in this file.

import board, cities, sim_state, sim_types, units

type
  UnitActionKind* = enum
    uaNone
    uaCenter
    uaMove
    uaTransfer
    uaBuildCity

  UnitAction* = object
    unitId*: int
    kind*: UnitActionKind
    dir*: Direction
    receiverId*: int
    resource*: Terrain
    amount*: int

  TileActionKind* = enum
    taNone
    taResearch
    taBuildWorker
    taBuildCart

  TileAction* = object
    cell*: int
    kind*: TileActionKind

  TurnOrders* = object
    ## One turn's whole action set, for both seats. Produced only by
    ## `micro.compileTurn`, which is a pure function of
    ## (world state, directive, seat).
    unitActions*: seq[UnitAction]
    tileActions*: seq[TileAction]

func actionFor(orders: TurnOrders, unitId: int): UnitAction =
  for action in orders.unitActions:
    if action.unitId == unitId:
      return action
  UnitAction(unitId: unitId, kind: uaNone)

func tileActionFor(orders: TurnOrders, cell: int): TileAction =
  for action in orders.tileActions:
    if action.cell == cell:
      return action
  TileAction(cell: cell, kind: taNone)

proc applyTileActions(world: var World, orders: TurnOrders, tick: int) =
  ## Step 3. City tiles act in ascending tile index, seat 0 then seat 1. A
  ## build is allowed only under S1's unit cap (`units < cityTiles`), and the
  ## new unit CANNOT act until the next turn because this turn's action list
  ## was fixed in step 2.
  for seat in 0 .. 1:
    let team = Team(seat)
    for cell in 0 ..< world.board.cellCount():
      if world.cities.teamOfCell[cell] != seat:
        continue
      if world.cities.cooldownOfCell[cell] != 0:
        continue
      let action = orders.tileActionFor(cell)
      case action.kind
      of taNone:
        discard
      of taResearch:
        let before = world.researchPoints[seat]
        world.researchPoints[seat] = before + 1
        world.cities.cooldownOfCell[cell] += world.config.cityCooldown
        for threshold in [world.config.coalResearch, world.config.uraniumResearch]:
          if before < threshold and world.researchPoints[seat] >= threshold:
            world.emitEvent(tick, SimEvent(
              kind: Research, seat: seat, cell: cell,
              amount: world.researchPoints[seat],
              resource: (if threshold == world.config.coalResearch: "coal"
                         else: "uranium")))
      of taBuildWorker, taBuildCart:
        if world.units.countOf(team) >= world.cities.tileCount(team):
          continue
        let kind = if action.kind == taBuildWorker: ukWorker else: ukCart
        world.units.spawn(team, kind, cell)
        inc world.unitsBuilt[seat]
        world.cities.cooldownOfCell[cell] += world.config.cityCooldown
        world.emitEvent(tick, SimEvent(
          kind: UnitBuilt, seat: seat, cell: cell, unitKind: $kind))

proc applyTransfers(world: var World, orders: TurnOrders) =
  ## Step 4, ascending giver unit id, evaluated against the ALREADY-UPDATED
  ## cargo state. A transfer to a non-adjacent or dead unit is discarded.
  var giverIds: seq[int] = @[]
  for unit in world.units.list:
    giverIds.add(unit.id)
  for giverId in giverIds:
    let action = orders.actionFor(giverId)
    if action.kind != uaTransfer:
      continue
    let giverIndex = world.units.indexOfId(giverId)
    let receiverIndex = world.units.indexOfId(action.receiverId)
    if giverIndex < 0 or receiverIndex < 0:
      continue
    if world.units.list[giverIndex].cooldownTenths != 0:
      continue
    if world.units.list[giverIndex].team != world.units.list[receiverIndex].team:
      continue
    var adjacent = false
    for neighbour in world.board.orthogonal(world.units.list[giverIndex].cell):
      if neighbour == world.units.list[receiverIndex].cell:
        adjacent = true
        break
    if not adjacent:
      continue
    let
      stock = world.units.list[giverIndex].stockOf(action.resource)
      space = world.units.list[receiverIndex].freeCargo(
        cargoCap(world, world.units.list[receiverIndex].kind))
      moved = min(action.amount, min(stock, space))
    if moved <= 0:
      continue
    world.units.list[giverIndex].addStock(action.resource, -moved)
    world.units.list[receiverIndex].addStock(action.resource, moved)
    world.units.list[giverIndex].cooldownTenths +=
      baseCooldown(world, world.units.list[giverIndex].kind)

proc applyCityBuilds(world: var World, orders: TurnOrders, tick: int) =
  ## Step 5, ascending unit id. A WORKER builds if and only if its cell is
  ## `empty` terrain, holds no city tile, and its cargo totals >= cityCost.
  ##
  ## Contested build: workers of BOTH teams on one cell => neither builds and
  ## neither spends. Two workers of the SAME team => the lower unit id builds.
  var wanted: seq[tuple[unitId, cell, team: int]] = @[]
  for unit in world.units.list:
    if unit.kind != ukWorker or unit.cooldownTenths != 0:
      continue
    if orders.actionFor(unit.id).kind != uaBuildCity:
      continue
    if world.board.terrain[unit.cell] != tEmpty:
      continue
    if world.cities.hasTile(unit.cell):
      continue
    if unit.totalCargo() < world.config.cityCost:
      continue
    wanted.add((unit.id, unit.cell, ord(unit.team)))
  for candidate in wanted:
    var contested = false
    var lowestSameTeam = candidate.unitId
    for other in wanted:
      if other.cell != candidate.cell or other.unitId == candidate.unitId:
        continue
      if other.team != candidate.team:
        contested = true
        break
      if other.unitId < lowestSameTeam:
        lowestSameTeam = other.unitId
    if contested or lowestSameTeam != candidate.unitId:
      continue
    let index = world.units.indexOfId(candidate.unitId)
    if index < 0:
      continue
    discard world.units.list[index].spendCheapestFirst(world.config.cityCost)
    ## A build is a worker action: it costs the CONFIGURED worker cooldown,
    ## not a literal that silently disagrees with `workerCooldown`.
    world.units.list[index].cooldownTenths += baseCooldown(world, ukWorker)
    let team = Team(candidate.team)
    let placed = world.cities.addTile(world.board, team, candidate.cell)
    world.board.road[candidate.cell] = world.config.maxRoad
    inc world.cityTilesBuilt[candidate.team]
    world.emitEvent(tick, SimEvent(
      kind: CityBuilt, seat: candidate.team, cell: candidate.cell,
      amount: world.cities.tileCount(team), content: $placed.cityId))

proc applyMovement(world: var World, orders: TurnOrders) =
  ## Step 6. (a) illegal targets are discarded; (b) the monotone BLOCKING
  ## FIXED POINT, which is order-independent by construction; (c) contention
  ## cancels every mover onto a contested non-friendly-city cell; (d) the
  ## survivors apply simultaneously and a CART paves the empty cell it lands on.
  let count = world.units.list.len
  var
    target = newSeq[int](count)
    moving = newSeq[bool](count)
    blocked = newSeq[bool](count)
  for i, unit in world.units.list:
    target[i] = unit.cell
    let action = orders.actionFor(unit.id)
    if action.kind != uaMove or unit.cooldownTenths != 0:
      continue
    let step = directionIndex(action.dir)
    if step < 0:
      continue
    let
      nx = world.board.cellX(unit.cell) + StepDx[step]
      ny = world.board.cellY(unit.cell) + StepDy[step]
    if not world.board.inside(nx, ny):
      continue                                   ## (a) off the board
    let cell = ny * world.board.size + nx
    let tileTeam = world.cities.teamOfCell[cell]
    if tileTeam >= 0 and tileTeam != ord(unit.team):
      continue                                   ## (a) opponent city tile
    target[i] = cell
    moving[i] = true

  # (b) fixed point: a move is blocked when its target is not a friendly city
  # tile of the mover and is occupied by a unit that is stationary or blocked.
  ## (b) + (c) as ONE MONOTONE FIXED POINT. They cannot be two passes: a move
  ## cancelled by CONTENTION becomes a stationary occupant, which must then
  ## block whatever was stepping into the cell it stayed on. Running contention
  ## after the blocking pass let exactly that through — a unit walked onto a
  ## neighbour whose own move had just been cancelled. `blocked` only ever goes
  ## true, so the loop terminates, and because nothing here depends on the
  ## iteration order the outcome is order-independent (the test asserts it by
  ## shuffling the evaluation order).
  ##
  ## EVERY occupant of a cell counts, not just the last one seen: a city that
  ## burned down at night legally strands a STACK on an ordinary cell.
  var occupants = newSeq[seq[int]](world.board.cellCount())
  for i, unit in world.units.list:
    occupants[unit.cell].add(i)
  var
    counts = newSeq[int](world.board.cellCount())
    changed = true
    guard = 0
  while changed and guard <= 2 * count + 2:
    changed = false
    inc guard
    for i in 0 ..< count:
      if not moving[i] or blocked[i]:
        continue
      let cell = target[i]
      if world.cities.teamOfCell[cell] == ord(world.units.list[i].team):
        continue                                 ## friendly city tiles stack
      for other in occupants[cell]:
        if other == i:
          continue
        if (not moving[other]) or blocked[other]:
          blocked[i] = true
          changed = true
          break
    for cell in 0 ..< counts.len:
      counts[cell] = 0
    for i in 0 ..< count:
      if moving[i] and not blocked[i]:
        inc counts[target[i]]
    for i in 0 ..< count:
      if not moving[i] or blocked[i]:
        continue
      let cell = target[i]
      if counts[cell] < 2:
        continue
      if world.cities.teamOfCell[cell] == ord(world.units.list[i].team):
        continue                                 ## friendly city tile: no cap
      blocked[i] = true
      changed = true

  # (d) apply.
  for i in 0 ..< count:
    if not moving[i]:
      continue
    if blocked[i]:
      inc world.blockedMoves[ord(world.units.list[i].team)]
      continue
    world.units.list[i].cell = target[i]
    world.units.list[i].cooldownTenths +=
      baseCooldown(world, world.units.list[i].kind)
    if world.units.list[i].kind == ukCart and
        world.board.terrain[target[i]] == tEmpty:
      world.board.road[target[i]] =
        min(world.config.maxRoad, world.board.road[target[i]] + 1)

proc collectResources(world: var World, tick: int) =
  ## Step 7. Only WORKERS collect. For each kind in the fixed order
  ## wood -> coal -> uranium, for each tile of that kind in ascending index,
  ## the eligible workers split the tile's remaining amount evenly with the
  ## first `amount mod |M|` of them taking one extra.
  for kind in [tWood, tCoal, tUranium]:
    let
      rate = (case kind
              of tWood: world.config.woodRate
              of tCoal: world.config.coalRate
              of tUranium: world.config.uraniumRate
              of tEmpty: 0)
      gate = (case kind
              of tCoal: world.config.coalResearch
              of tUranium: world.config.uraniumResearch
              else: 0)
    for cell in 0 ..< world.board.cellCount():
      if world.board.terrain[cell] != kind or world.board.amount[cell] <= 0:
        continue
      var miners: seq[int] = @[]
      for i, unit in world.units.list:
        if unit.kind != ukWorker:
          continue
        if world.researchPoints[ord(unit.team)] < gate:
          continue
        if unit.freeCargo(cargoCap(world, unit.kind)) <= 0:
          continue
        if unit.cell == cell:
          miners.add(i)
          continue
        var adjacent = false
        for neighbour in world.board.orthogonal(cell):
          if neighbour == unit.cell:
            adjacent = true
            break
        if adjacent:
          miners.add(i)
      if miners.len == 0:
        continue
      let available = world.board.amount[cell]
      var taken = 0
      for position, index in miners:
        var share = rate
        if miners.len * rate > available:
          share = available div miners.len
          if position < available mod miners.len:
            inc share
        let capped = min(share, world.units.list[index].freeCargo(
          cargoCap(world, world.units.list[index].kind)))
        if capped <= 0:
          continue
        world.units.list[index].addStock(kind, capped)
        world.resourcesMined[ord(world.units.list[index].team)][ord(kind) - 1] +=
          int64(capped)
        taken += capped
      world.board.amount[cell] = max(0, available - taken)
      if available > 0 and world.board.amount[cell] == 0:
        world.emitEvent(tick, SimEvent(
          kind: Depleted, cell: cell, resource: $kind))

proc depositCargo(world: var World) =
  ## Step 8. Every unit standing on a FRIENDLY city tile empties its whole
  ## cargo into that tile's city, every turn, day and night. It is the only way
  ## fuel enters a city.
  for i in 0 ..< world.units.list.len:
    let cell = world.units.list[i].cell
    if world.cities.teamOfCell[cell] != ord(world.units.list[i].team):
      continue
    if world.units.list[i].totalCargo() == 0:
      continue
    let cityIndex = world.cities.indexOfCity(world.cities.cityOfCell[cell])
    if cityIndex < 0:
      continue
    world.cities.list[cityIndex].fuel += world.units.list[i].cargoFuel()
    world.units.list[i].clearCargo()

proc nightBurn(world: var World, tick: int) =
  ## Step 9. Cities first (ascending city id), units second (ascending unit id)
  ## — on purpose: a unit sheltering in a city that just burned down pays its
  ## own upkeep this turn.
  var doomed: seq[int] = @[]
  for city in world.cities.list:
    let bill = city.upkeep(world.board, world.config.cityUpkeepPerTile,
      world.config.cityAdjacencyDiscount)
    if city.fuel >= int64(bill):
      continue
    doomed.add(city.id)
  for id in doomed:
    let index = world.cities.indexOfCity(id)
    if index < 0:
      continue
    let
      seat = ord(world.cities.list[index].team)
      tiles = world.cities.list[index].cells.len
      firstCell = world.cities.list[index].cells[0]
    for cell in world.cities.destroyCity(id):
      world.burntStack[cell] = true
    world.cityTilesLost[seat] += tiles
    world.emitEvent(tick, SimEvent(
      kind: CityLost, seat: seat, cell: firstCell, amount: tiles,
      cause: "out of fuel", content: $id))
  for city in world.cities.list.mitems:
    let bill = city.upkeep(world.board, world.config.cityUpkeepPerTile,
      world.config.cityAdjacencyDiscount)
    city.fuel -= int64(bill)
  var dead: seq[int] = @[]
  for unit in world.units.list:
    if world.cities.teamOfCell[unit.cell] == ord(unit.team):
      continue                                   ## sheltered: pays nothing
    dead.add(unit.id)
  for id in dead:
    let index = world.units.indexOfId(id)
    if index < 0:
      continue
    let
      kind = world.units.list[index].kind
      need = (if kind == ukWorker: world.config.workerUpkeep
              else: world.config.cartUpkeep)
    if world.units.list[index].burnForFuel(need):
      continue
    let
      seat = ord(world.units.list[index].team)
      cell = world.units.list[index].cell
    world.units.removeAt(index)
    inc world.unitsLost[seat]
    world.emitEvent(tick, SimEvent(
      kind: UnitLost, seat: seat, cell: cell, unitKind: $kind,
      cause: "night upkeep"))

proc tickCooldowns(world: var World) =
  ## Step 10. A worker on a fully paved road recovers 22 tenths a turn and so
  ## acts every turn instead of every second turn — that is what a cart is for.
  for unit in world.units.list.mitems:
    let recovery = 10 + 2 * world.board.road[unit.cell]
    unit.cooldownTenths = max(0, unit.cooldownTenths - recovery)
  for cell in 0 ..< world.board.cellCount():
    if world.cities.cooldownOfCell[cell] > 0:
      world.cities.cooldownOfCell[cell] =
        max(0, world.cities.cooldownOfCell[cell] - 10)

proc clearBurntStacks(world: var World) =
  ## A stranded stack stops being tolerated the moment its cell is back down to
  ## one occupant.
  var occupied = newSeq[int](world.board.cellCount())
  for unit in world.units.list:
    inc occupied[unit.cell]
  for cell in 0 ..< world.board.cellCount():
    if world.burntStack[cell] and occupied[cell] <= 1:
      world.burntStack[cell] = false

proc regrowWood(world: var World) =
  ## Step 11. A wood tile mined to EXACTLY zero never comes back — the integer
  ## transcription of S1's 1.02 growth rate, and the reason over-harvesting is
  ## a real mistake.
  for cell in 0 ..< world.board.cellCount():
    if world.board.terrain[cell] != tWood:
      continue
    let amount = world.board.amount[cell]
    if amount <= 0 or amount >= WoodRegrowCap:
      continue
    world.board.amount[cell] =
      min(WoodRegrowCap, amount + max(1, amount div 50))

proc resolveTurn*(world: var World, orders: TurnOrders, tick: int) =
  ## Steps 3-11 in order. Nothing else mutates the world.
  let night = world.isNight(world.turn)
  world.applyTileActions(orders, tick)
  world.applyTransfers(orders)
  world.applyCityBuilds(orders, tick)
  world.applyMovement(orders)
  world.collectResources(tick)
  world.depositCargo()
  if night:
    world.nightBurn(tick)
    if world.nightTurnIndex(world.turn) == world.nightLength():
      for seat in 0 .. 1:
        if world.cities.tileCount(Team(seat)) > 0:
          inc world.nightsSurvived[seat]
  world.tickCooldowns()
  world.clearBurntStacks()
  world.regrowWood()
