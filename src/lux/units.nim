## Units: the array, the global id counter, cargo helpers and the fuel table.
##
## PURE INTEGER — no floating point in this file.

import sim_types

type
  Unit* = object
    id*: int             ## global creation counter; the ascending-id order
                         ## every rule in `resolve.nim` iterates in.
    team*: Team
    kind*: UnitKind
    cell*: int
    wood*: int
    coal*: int
    uranium*: int
    cooldownTenths*: int

  Units* = object
    list*: seq[Unit]     ## always sorted by ascending `id`.
    nextId*: int

func totalCargo*(unit: Unit): int =
  unit.wood + unit.coal + unit.uranium

func cargoFuel*(unit: Unit): int64 =
  int64(unit.wood) * WoodFuel + int64(unit.coal) * CoalFuel +
    int64(unit.uranium) * UraniumFuel

func freeCargo*(unit: Unit, cap: int): int =
  max(0, cap - unit.totalCargo())

func stockOf*(unit: Unit, kind: Terrain): int =
  case kind
  of tWood: unit.wood
  of tCoal: unit.coal
  of tUranium: unit.uranium
  of tEmpty: 0

proc addStock*(unit: var Unit, kind: Terrain, amount: int) =
  case kind
  of tWood: unit.wood += amount
  of tCoal: unit.coal += amount
  of tUranium: unit.uranium += amount
  of tEmpty: discard

proc clearCargo*(unit: var Unit) =
  unit.wood = 0
  unit.coal = 0
  unit.uranium = 0

proc spendCheapestFirst*(unit: var Unit, resourceUnits: int): int =
  ## Spends exactly `resourceUnits` RESOURCE UNITS, cheapest kind first
  ## (wood, then coal, then uranium) — the city-build cost. Returns what was
  ## actually spent; the caller has already checked the unit can pay.
  var left = resourceUnits
  let takeWood = min(left, unit.wood)
  unit.wood -= takeWood
  left -= takeWood
  let takeCoal = min(left, unit.coal)
  unit.coal -= takeCoal
  left -= takeCoal
  let takeUranium = min(left, unit.uranium)
  unit.uranium -= takeUranium
  left -= takeUranium
  resourceUnits - left

proc burnForFuel*(unit: var Unit, fuelNeeded: int): bool =
  ## Night upkeep: spends whole resource units CHEAPEST FIRST until the paid
  ## fuel reaches `fuelNeeded`. Overpay is lost. Returns false — and leaves the
  ## unit stripped — when even spending everything cannot cover it, which is
  ## the unit dying.
  var paid = 0
  while paid < fuelNeeded and unit.wood > 0:
    dec unit.wood
    paid += WoodFuel
  while paid < fuelNeeded and unit.coal > 0:
    dec unit.coal
    paid += CoalFuel
  while paid < fuelNeeded and unit.uranium > 0:
    dec unit.uranium
    paid += UraniumFuel
  paid >= fuelNeeded

proc spawn*(
  units: var Units, team: Team, kind: UnitKind, cell: int
): int {.discardable.} =
  ## Appends a new unit with the next global id and returns that id. The list
  ## stays sorted by id because ids only ever increase.
  result = units.nextId
  inc units.nextId
  units.list.add(Unit(
    id: result, team: team, kind: kind, cell: cell, cooldownTenths: 0))

func indexOfId*(units: Units, id: int): int =
  for i, unit in units.list:
    if unit.id == id:
      return i
  -1

proc removeAt*(units: var Units, index: int) =
  units.list.delete(index)

func countOf*(units: Units, team: Team): int =
  for unit in units.list:
    if unit.team == team:
      inc result

func countOf*(units: Units, team: Team, kind: UnitKind): int =
  for unit in units.list:
    if unit.team == team and unit.kind == kind:
      inc result
