## The broadcast layer: `stepEvents`, `buildStateJson` and the roster/teams
## blocks the inherited chrome reads. Forked from coworld-ctf's
## `src/ctf/broadcast.nim` — retargeted fields, same structure, so
## `chrome_common.js` keeps working byte-for-byte.
##
## ONE object per presentation frame, identical live and in replay, and the
## only thing the renderer reads.

import std/[json]

import sim

type
  BroadcastTracker* = object
    ## Per-viewer delta state. `terrain` and `roads` ship as DELTAS (full
    ## arrays on the first frame and after any resync), which is what keeps a
    ## 360-frame state stream small.
    eventsConsumed*: int
    lastAmount*: seq[int]
    lastRoad*: seq[int]
    primed*: bool

proc initBroadcastTracker*(): BroadcastTracker =
  BroadcastTracker(eventsConsumed: 0, primed: false)

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## After a seek the viewer's picture is stale: forget the deltas and ship the
  ## whole board on the next frame.
  tracker.primed = false
  tracker.eventsConsumed = sim.world.events.len

proc eventJson(sim: SimServer, event: SimEvent): JsonNode =
  result = %*{"k": event.kind.key(), "t": event.tick}
  case event.kind
  of PhaseChange:
    result["to"] = %event.content
  of Dawn:
    result["cycle"] = %(event.amount + 1)
  of Dusk:
    result["cycle"] = %(event.amount + 1)
    result["cityTiles"] = %[event.cell div 1000, event.cell mod 1000]
    result["fuel"] = %[sim.world.cities.totalFuel(Red),
      sim.world.cities.totalFuel(Blue)]
  of CityBuilt:
    result["seat"] = %event.seat
    result["cell"] = %event.cell
    result["tiles"] = %event.amount
    result["cityId"] = %event.content
  of CityLost:
    result["seat"] = %event.seat
    result["cell"] = %event.cell
    result["tiles"] = %event.amount
    result["cityId"] = %event.content
  of UnitBuilt:
    result["seat"] = %event.seat
    result["cell"] = %event.cell
    result["kind"] = %event.unitKind
  of UnitLost:
    result["seat"] = %event.seat
    result["cell"] = %event.cell
    result["kind"] = %event.unitKind
    result["cause"] = %event.cause
  of Research:
    result["seat"] = %event.seat
    result["kind"] = %event.resource
    result["points"] = %event.amount
  of Depleted:
    result["cell"] = %event.cell
    result["kind"] = %event.resource
  of Directive:
    result["seat"] = %event.seat
    result["stance"] = %event.content
    result["note"] = %event.cause
  of Fallback:
    result["seat"] = %event.seat
    result["cause"] = %event.cause

proc stepEvents*(
  sim: var SimServer, tracker: var BroadcastTracker, into: JsonNode
) =
  ## Derives this frame's events from the sim's own event buffer, so they cost
  ## no replay bytes and are identical live and in replay.
  while tracker.eventsConsumed < sim.world.events.len:
    into.add(eventJson(sim, sim.world.events[tracker.eventsConsumed]))
    inc tracker.eventsConsumed

proc rosterJson*(sim: SimServer): JsonNode =
  ## SPECTATOR SIDE. `name` is the seat's REAL policy name; `alias` is the
  ## anonymous in-game name a seat itself sees. Both, never either.
  result = newJArray()
  for seat in 0 .. 1:
    result.add(%*{
      "s": seat,
      "seat": seat,
      "team": teamText(teamForSlot(seat)),
      "name": sim.seats[seat].name,
      "pol": sim.seats[seat].policyLabel,
      "alias": cogAlias(seat),
      "col": (if seat == 0: "#e0523a" else: "#3f7cc4"),
      "kind": (if sim.seats[seat].isLlm: "llm" else: "scripted"),
      "fallbacks": sim.fallbackTurns[seat]
    })

proc teamsJson*(sim: SimServer): JsonNode =
  ## The inherited chrome's team block. `lives` carries CITY TILES so the
  ## starter's momentum accumulator draws the city-tile lead with no edit.
  let standing = sim.world.standing()
  result = newJObject()
  for seat in 0 .. 1:
    result[teamText(Team(seat))] = %*{
      "lives": standing.cityTiles[seat],
      "cityTiles": standing.cityTiles[seat],
      "units": standing.units[seat],
      "fuel": standing.fuel[seat],
      "research": standing.research[seat],
      "policies": [sim.seats[seat].name]
    }

proc directivesJson*(sim: SimServer): JsonNode =
  ## The two most recent directives — where the feed's commander lines come
  ## from. The `note` is SPECTATOR-ONLY and appears nowhere a seat can read it.
  result = newJArray()
  for seat in 0 .. 1:
    result.add(%*{
      "seat": seat,
      "alias": cogAlias(seat),
      "turn": sim.lastDirectiveTurn[seat],
      "stance": $sim.directive[seat].stance,
      "source": $sim.directive[seat].source,
      "note": sim.directive[seat].note
    })

proc buildStateJson*(
  sim: var SimServer,
  tracker: var BroadcastTracker,
  events: JsonNode,
  playing: bool,
  speed, maxTick: int,
  looping, replayEnabled: bool,
  mismatchTick, startTick: int,
  fastForward: bool,
  skipLulls: bool,
  lead: JsonNode = nil,
  lulls: JsonNode = nil,
  beats: JsonNode = nil
): string =
  let
    world = sim.world
    turn = min(world.turn, sim.config.maxTurns)
    night = world.isNight(turn)
  var node = %*{
    "t": sim.tickCount,
    "mt": sim.config.maxTurns,
    "st": max(0, startTick),
    "mx": max(1, maxTick),
    "ph": $sim.phase,
    "lob": max(0, (sim.config.startWaitTicks - sim.tickCount) div TargetFps),
    "sp": speed,
    "pl": playing,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForward,
    "en": replayEnabled,
    "mm": mismatchTick,
    "pov": -1,
    "bs": 1,
    "teams": sim.teamsJson(),
    "roster": sim.rosterJson(),
    "events": events,
    "dir": sim.directivesJson()
  }
  # ---- the lux-ai board block --------------------------------------------
  node["turn"] = %turn
  node["turns"] = %sim.config.maxTurns
  node["cycle"] = %(world.cycleOf(turn) + 1)
  node["cycles"] = %((sim.config.maxTurns + sim.config.cycleLength - 1) div
    sim.config.cycleLength)
  node["night"] = %night
  node["nightTurn"] = %world.nightTurnIndex(turn)
  node["nightTurns"] = %world.nightLength()
  node["dayLength"] = %sim.config.dayLength
  node["size"] = %world.board.size
  node["res"] = %[world.researchPoints[0], world.researchPoints[1]]
  node["coalAt"] = %sim.config.coalResearch
  node["uraniumAt"] = %sim.config.uraniumResearch

  if tracker.lastAmount.len != world.board.cellCount():
    tracker.lastAmount = newSeq[int](world.board.cellCount())
    tracker.lastRoad = newSeq[int](world.board.cellCount())
    tracker.primed = false
  var
    terrain = newJArray()
    roads = newJArray()
  for cell in 0 ..< world.board.cellCount():
    let
      amount = world.board.amount[cell]
      road = world.board.road[cell]
    if world.board.terrain[cell] != tEmpty and
        ((not tracker.primed) or amount != tracker.lastAmount[cell]):
      terrain.add(%*{"i": cell, "k": $world.board.terrain[cell], "a": amount})
    if (not tracker.primed and road > 0) or
        (tracker.primed and road != tracker.lastRoad[cell]):
      roads.add(%*{"i": cell, "l": road})
    tracker.lastAmount[cell] = amount
    tracker.lastRoad[cell] = road
  tracker.primed = true
  node["terrain"] = terrain
  node["roads"] = roads
  node["full"] = %(terrain.len > 0 and roads.len >= 0)

  var cityArray = newJArray()
  for city in world.cities.list:
    var tiles = newJArray()
    for cell in city.cells:
      tiles.add(%cell)
    cityArray.add(%*{
      "id": city.id,
      "seat": ord(city.team),
      "fuel": city.fuel,
      "upkeep": city.upkeep(world.board, sim.config.cityUpkeepPerTile,
        sim.config.cityAdjacencyDiscount),
      "tiles": tiles
    })
  node["cities"] = cityArray

  var unitArray = newJArray()
  for unit in world.units.list:
    unitArray.add(%*{
      "u": unit.id,
      "seat": ord(unit.team),
      "k": $unit.kind,
      "i": unit.cell,
      "w": unit.wood,
      "c": unit.coal,
      "r": unit.uranium,
      "cd": unit.cooldownTenths
    })
  node["units"] = unitArray

  let standing = world.standing()
  node["score"] = %*{
    "cityTiles": [standing.cityTiles[0], standing.cityTiles[1]],
    "units": [standing.units[0], standing.units[1]],
    "fuel": [standing.fuel[0], standing.fuel[1]],
    "leader": (if standing.cityTiles[0] > standing.cityTiles[1]: 0
               elif standing.cityTiles[1] > standing.cityTiles[0]: 1
               else: -1)
  }
  if lead != nil and lead.len > 0:
    var pts = newJArray()
    for point in lead:
      pts.add(point)
    node["lead"] = %*{"teams": ["red", "blue"], "pts": pts}
  if lulls != nil:
    node["lulls"] = lulls
  if beats != nil:
    node["beats"] = beats
  if sim.phase == GameOver:
    node["over"] = %*{
      "winner": (if sim.outcome.winner < 0: ""
                 else: teamText(Team(sim.outcome.winner))),
      "draw": sim.outcome.winner < 0,
      "reason": $sim.reason,
      "endRule": $sim.endRule,
      "t": sim.gameOverTick
    }
    node["results"] = parseJson(sim.luxResultsJson())
  $node
