## The world state, the per-turn `gameHash` chain, the sim guard and the event
## buffer. Forked from coworld-ctf's `src/ctf/sim_state.nim`.
##
## `gameHash` is the integrity chain the browser checks: the viewer re-steps
## the same Nim modules from the recorded directives and compares its own hash
## against the recorded one EVERY tick, so one divergent bit is caught at the
## tick it happens.

import std/[json, strutils]

import board, cities, sim_config, sim_types, units

type
  World* = object
    config*: GameConfig
    board*: Board
    units*: Units
    cities*: Cities
    turn*: int
    researchPoints*: array[2, int]
    unitsBuilt*: array[2, int]
    unitsLost*: array[2, int]
    cityTilesBuilt*: array[2, int]
    cityTilesLost*: array[2, int]
    blockedMoves*: array[2, int]
    nightsSurvived*: array[2, int]
    resourcesMined*: array[2, array[3, int64]]
    directiveBytes*: array[2, array[13, uint8]]
      ## Each seat's INSTALLED structured directive — the 13 bytes that are an
      ## input record in the replay and are mixed into `gameHash`. The note,
      ## the source and the latency are excluded: nothing a commander SAYS may
      ## move the hash chain.
    burntStack*: seq[bool]
      ## Cells a city was destroyed on while units stood there. S1 lets any
      ## number of units stack on a friendly city tile, so a city that burns
      ## down at night legally STRANDS a stack on an ordinary cell — the guard
      ## below tolerates it until the units disperse, and clears the flag the
      ## moment a cell is back down to one occupant. Derived from the same
      ## events on both sides of the wire, and never hashed.
    events*: seq[SimEvent]
    eventLoggingEnabled*: bool

func cellCount*(world: World): int = world.board.cellCount()

func isNight*(world: World, turn: int): bool =
  (turn mod world.config.cycleLength) >= world.config.dayLength

func cycleOf*(world: World, turn: int): int =
  turn div world.config.cycleLength

func nightTurnIndex*(world: World, turn: int): int =
  ## 1-based turn number inside the current night, 0 during the day.
  let phase = turn mod world.config.cycleLength
  if phase < world.config.dayLength: 0 else: phase - world.config.dayLength + 1

func nightLength*(world: World): int =
  world.config.cycleLength - world.config.dayLength

func turnsToDusk*(world: World, turn: int): int =
  let phase = turn mod world.config.cycleLength
  if phase < world.config.dayLength: world.config.dayLength - phase else: 0

func turnsToDawn*(world: World, turn: int): int =
  let phase = turn mod world.config.cycleLength
  if phase < world.config.dayLength: 0 else: world.config.cycleLength - phase

proc emitEvent*(world: var World, tick: int, event: sink SimEvent) =
  if not world.eventLoggingEnabled:
    return
  var row = event
  row.tick = tick
  world.events.add(row)

proc initWorld*(config: GameConfig): World =
  result.config = config
  result.board = generateBoard(
    config.mapSize, config.seed,
    config.woodClusters, config.coalClusters, config.uraniumClusters,
    config.woodStart, config.coalStart, config.uraniumStart)
  result.cities = initCities(result.board.cellCount())
  result.burntStack = newSeq[bool](result.board.cellCount())
  result.units = Units(nextId: 0)
  result.eventLoggingEnabled = true
  for seat in 0 .. 1:
    let cell = result.board.startCell[seat]
    result.cities.addTile(result.board, Team(seat), cell)
    result.board.road[cell] = result.config.maxRoad
    result.units.spawn(Team(seat), ukWorker, cell)
    result.unitsBuilt[seat] = 1
    result.cityTilesBuilt[seat] = 1

# ---------------------------------------------------------------------------
#  gameHash
# ---------------------------------------------------------------------------

func mixHash*(hash: var uint64, value: int) =
  ## FNV-1a style mix over a 64-bit accumulator. Every quantity that enters the
  ## chain is an integer, so the mix is exact in wasm32 too.
  hash = hash xor uint64(cast[uint32](int32(value)))
  hash = hash * 0x100000001B3'u64
  hash = hash xor (hash shr 29)

func mixHash64*(hash: var uint64, value: int64) =
  hash.mixHash(int(value and 0xFFFFFFFF'i64))
  hash.mixHash(int((value shr 32) and 0xFFFFFFFF'i64))

func gameHash*(world: World): uint64 =
  ## The fixed mix order of the design note. Add a field only at the END and
  ## bump `GameVersion` in the same commit — the order IS the format.
  result = 0xCBF29CE484222325'u64
  result.mixHash(world.turn)
  for unit in world.units.list:
    result.mixHash(unit.id)
    result.mixHash(ord(unit.team))
    result.mixHash(ord(unit.kind))
    result.mixHash(world.board.cellX(unit.cell))
    result.mixHash(world.board.cellY(unit.cell))
    result.mixHash(unit.wood)
    result.mixHash(unit.coal)
    result.mixHash(unit.uranium)
    result.mixHash(unit.cooldownTenths)
  for cell in 0 ..< world.board.cellCount():
    if world.cities.cityOfCell[cell] >= 0:
      result.mixHash(world.cities.teamOfCell[cell])
      result.mixHash(cell)
      result.mixHash(world.cities.cityOfCell[cell])
      result.mixHash(world.cities.cooldownOfCell[cell])
  for city in world.cities.list:
    result.mixHash(city.id)
    result.mixHash(ord(city.team))
    result.mixHash64(city.fuel)
    result.mixHash(city.cells.len)
  for cell in 0 ..< world.board.cellCount():
    if world.board.terrain[cell] != tEmpty:
      result.mixHash(ord(world.board.terrain[cell]))
      result.mixHash(world.board.amount[cell])
  for cell in 0 ..< world.board.cellCount():
    if world.board.road[cell] != 0:
      result.mixHash(cell)
      result.mixHash(world.board.road[cell])
  for seat in 0 .. 1:
    result.mixHash(world.researchPoints[seat])
  for seat in 0 .. 1:
    result.mixHash(world.unitsBuilt[seat])
    result.mixHash(world.unitsLost[seat])
    result.mixHash(world.cityTilesBuilt[seat])
    result.mixHash(world.cityTilesLost[seat])
    result.mixHash(world.blockedMoves[seat])
  for seat in 0 .. 1:
    for byteValue in world.directiveBytes[seat]:
      result.mixHash(int(byteValue))

# ---------------------------------------------------------------------------
#  The sim guard
# ---------------------------------------------------------------------------

proc checkLuxInvariants*(world: World) =
  ## Evaluated every turn (step 12). A trip raises `LuxGuardError`, which the
  ## server settles as `fault`/`sim_fault` with the artifacts still written.
  let cells = world.board.cellCount()
  var occupied = newSeq[int](cells)
  for i in 0 ..< cells:
    occupied[i] = 0
  for unit in world.units.list:
    if unit.cell < 0 or unit.cell >= cells:
      raise newException(LuxGuardError, "unit " & $unit.id & " is off the board")
    let tileTeam = world.cities.teamOfCell[unit.cell]
    if tileTeam >= 0 and tileTeam != ord(unit.team):
      raise newException(LuxGuardError,
        "unit " & $unit.id & " stands on an opponent city tile")
    if unit.wood < 0 or unit.coal < 0 or unit.uranium < 0:
      raise newException(LuxGuardError,
        "unit " & $unit.id & " carries a negative resource")
    if unit.totalCargo() > cargoCap(unit.kind):
      raise newException(LuxGuardError,
        "unit " & $unit.id & " is over its cargo cap")
    inc occupied[unit.cell]
    if occupied[unit.cell] > 1 and not world.cities.hasTile(unit.cell) and
        not world.burntStack[unit.cell]:
      raise newException(LuxGuardError,
        "two units share the non-city cell " & $unit.cell)
  for cell in 0 ..< cells:
    let kind = world.board.terrain[cell]
    if kind != tEmpty:
      let cap = 2 * startAmount(kind, world.config.woodStart,
        world.config.coalStart, world.config.uraniumStart)
      if world.board.amount[cell] < 0 or world.board.amount[cell] > cap:
        raise newException(LuxGuardError,
          "resource amount out of range at cell " & $cell)
    if world.board.road[cell] < 0 or world.board.road[cell] > world.config.maxRoad:
      raise newException(LuxGuardError, "road level out of range at cell " & $cell)
    if world.cities.hasTile(cell) and
        world.board.road[cell] != world.config.maxRoad:
      raise newException(LuxGuardError,
        "city tile at cell " & $cell & " is not fully paved")
  var counted: array[2, int]
  for city in world.cities.list:
    if city.fuel < 0 or city.fuel >= MaxCityFuel:
      raise newException(LuxGuardError,
        "city " & $city.id & " fuel out of range: " & $city.fuel)
    if not city.connectedComponent(world.board):
      raise newException(LuxGuardError,
        "city " & $city.id & " is not one connected component")
    for cell in city.cells:
      if world.cities.cityOfCell[cell] != city.id or
          world.cities.teamOfCell[cell] != ord(city.team):
        raise newException(LuxGuardError,
          "city tile bookkeeping disagrees at cell " & $cell)
    counted[ord(city.team)] += city.cells.len
  for seat in 0 .. 1:
    if world.researchPoints[seat] < 0:
      raise newException(LuxGuardError, "negative research points")
    if counted[seat] != world.cities.tileCount(Team(seat)):
      raise newException(LuxGuardError, "city tile count disagrees")
  if world.turn > world.config.maxTurns:
    raise newException(LuxGuardError, "turn ran past maxTurns")
  if not world.board.mirrorSymmetric():
    raise newException(LuxGuardError, "the island is no longer mirror-symmetric")

# ---------------------------------------------------------------------------
#  Event vocabulary
# ---------------------------------------------------------------------------

func key*(kind: SimEventKind): string =
  case kind
  of PhaseChange: "phase"
  of Dawn: "dawn"
  of Dusk: "dusk"
  of CityBuilt: "citybuilt"
  of CityLost: "citylost"
  of UnitBuilt: "unitbuilt"
  of UnitLost: "unitlost"
  of Research: "research"
  of Depleted: "depleted"
  of Directive: "directive"
  of Fallback: "fallback"

proc jsonRow*(event: SimEvent): JsonNode =
  %*{
    "tick": event.tick,
    "kind": event.kind.key(),
    "seat": event.seat,
    "cell": event.cell,
    "amount": event.amount,
    "unit": event.unitKind,
    "resource": event.resource,
    "cause": event.cause,
    "content": event.content
  }

proc eventsJsonl*(
  events: openArray[SimEvent], ticks: int, summaryExtra: JsonNode = nil
): string =
  ## One JSON-lines row per event, then the MANDATORY trailing summary row —
  ## how a reader tells "no events" from "the file was truncated", carrying the
  ## GameVersion the events were produced under.
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %events.len
  summary["gameVersion"] = %GameVersion
  if summaryExtra != nil:
    for key, value in summaryExtra:
      summary[key] = value
  lines.add($summary)
  result = lines.join("\n") & "\n"
