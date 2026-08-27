## The step loop, the `Lobby -> Playing -> GameOver` phase machine, the seat
## observation, and the results document. Imports and RE-EXPORTS the sim
## modules as the starter's `sim.nim` does, so `import lux/sim` sees everything.
##
## NOTHING in this module reaches the network: the same file compiles natively
## into `/bin/lux-ai` and, through `replay-viewer/config.nims`, to wasm for the
## browser viewer. That is the whole reason the game lives in the starter's
## language.

import std/[json]

import
  baselines, board, cities, directives, micro, resolve, roster, scoring,
  sim_config, sim_state, sim_types, units

export
  baselines, board, cities, directives, micro, resolve, roster, scoring,
  sim_config, sim_state, sim_types, units

type
  SimServer* = object
    config*: GameConfig
    world*: World
    cache*: MicroCache
    phase*: Phase
    tickCount*: int
    gameStartTick*: int
    gameOverTick*: int
    seats*: array[2, Seat]
    directive*: array[2, Directive]
    haveDirective*: array[2, bool]
    reason*: EndReason
    endRule*: EndRule
    stopDetail*: string
    outcome*: Outcome
    finalStanding*: Standing
    settled*: bool
    llmTurns*: array[2, int]
    fallbackTurns*: array[2, int]
    directivesRejected*: array[2, int]
    gameEventLoggingEnabled*: bool
    lastDirectiveTurn*: array[2, int]

func seatCount*(sim: SimServer): int = 2

func currentTurn*(sim: SimServer): int = sim.world.turn

func gameTicksElapsed*(sim: SimServer): int =
  ## Lobby ticks are NOT Lux turns; this is the starter's split.
  if sim.gameStartTick < 0: 0 else: max(0, sim.tickCount - sim.gameStartTick)

func isDirectiveTurn*(sim: SimServer, turn: int): bool =
  turn mod max(1, sim.config.directiveEvery) == 0

func directiveIndex*(sim: SimServer, turn: int): int =
  turn div max(1, sim.config.directiveEvery)

func directiveCount*(sim: SimServer): int =
  (sim.config.maxTurns + sim.config.directiveEvery - 1) div
    max(1, sim.config.directiveEvery)

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.world = initWorld(config)
  result.phase = Lobby
  result.tickCount = 0
  result.gameStartTick = -1
  result.gameOverTick = -1
  result.reason = erComplete
  result.endRule = erlNone
  result.gameEventLoggingEnabled = true
  result.world.eventLoggingEnabled = true
  for seat in 0 .. 1:
    result.seats[seat].slot = seat
    result.seats[seat].name = "baseline-" & $seat
    result.seats[seat].policyLabel = "lux-ai-forester"
    result.seats[seat].baseline = $blForester
    result.directive[seat] = foresterDirective(result.world, seat)
    result.lastDirectiveTurn[seat] = -1
  if config.playerNames.len >= 2:
    for seat in 0 .. 1:
      if config.playerNames[seat].len > 0:
        result.seats[seat].name = config.playerNames[seat]

func alias*(sim: SimServer, seat: int): string = cogAlias(seat)

proc setDirective*(sim: var SimServer, seat: int, directive: Directive) =
  ## Installs one seat's directive and freezes its 13 structured bytes into the
  ## world, where `gameHash` picks them up. Called live by `decide.turn` and at
  ## playback by the replay runtime, from the SAME bytes.
  sim.directive[seat] = directive
  sim.haveDirective[seat] = true
  sim.world.directiveBytes[seat] = encodeDirective(directive)
  sim.lastDirectiveTurn[seat] = sim.world.turn

proc applyDirectiveBytes*(sim: var SimServer, seat: int, bytes: openArray[uint8]) =
  ## The playback half of `setDirective`: the recorded input record, decoded
  ## and installed before the same turn is stepped.
  var directive = decodeDirective(bytes)
  directive.source = sim.directive[seat].source
  sim.setDirective(seat, directive)

proc beginPlaying*(sim: var SimServer) =
  if sim.phase != Lobby:
    return
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.world.turn = 0
  sim.world.emitEvent(sim.tickCount, SimEvent(
    kind: PhaseChange, content: "playing"))

proc settle*(sim: var SimServer, reason: EndReason, rule: EndRule) =
  ## Scores by the REAL ladder at the turn the clock stopped — a `deadline`
  ## episode is never zeroed, so it stays rankable.
  if sim.settled:
    return
  sim.settled = true
  sim.finalStanding = sim.world.standing()
  sim.outcome = scoring.settle(sim.finalStanding)
  sim.reason = reason
  sim.endRule = rule
  sim.phase = GameOver
  sim.gameOverTick = sim.tickCount
  sim.world.emitEvent(sim.tickCount, SimEvent(
    kind: PhaseChange, content: "gameover"))

proc applyWallClockStop*(sim: var SimServer) =
  ## The ONE load-bearing chat record. A wall-clock stop is a fact no
  ## re-simulation can derive, so it is recorded and applied on BOTH sides by
  ## this same proc, before that turn's step (the particle-worlds r2 scar).
  if sim.phase != Playing:
    return
  sim.stopDetail = "wall-clock budget of " &
    $sim.config.wallClockBudgetSeconds & " s elapsed at turn " &
    $sim.world.turn
  sim.settle(erDeadline, erlWallClock)

proc stepPlaying(sim: var SimServer) =
  let turn = sim.world.turn
  let wasNight = sim.world.isNight(max(0, turn - 1))
  let night = sim.world.isNight(turn)
  if night and not wasNight:
    sim.world.emitEvent(sim.tickCount, SimEvent(
      kind: Dusk, amount: sim.world.cycleOf(turn),
      cell: sim.world.cities.tileCount(Red) * 1000 +
        sim.world.cities.tileCount(Blue)))
  elif (not night) and wasNight and turn > 0:
    sim.world.emitEvent(sim.tickCount, SimEvent(
      kind: Dawn, amount: sim.world.cycleOf(turn)))
  let orders = sim.cache.compileBothSeats(sim.world, sim.directive)
  sim.world.resolveTurn(orders, sim.tickCount)
  sim.world.checkLuxInvariants()
  sim.world.turn = turn + 1
  if sim.world.turn >= sim.config.maxTurns:
    sim.settle(erComplete, erlFullTime)
    return
  for seat in 0 .. 1:
    if sim.world.eliminated(seat):
      sim.settle(erComplete, erlEliminated)
      return

proc step*(sim: var SimServer) =
  ## One tick. During `Playing` a tick IS a Lux turn.
  case sim.phase
  of Lobby:
    let joined = sim.seats[0].joined and sim.seats[1].joined
    if (joined and sim.tickCount >= sim.config.startWaitTicks) or
        sim.tickCount >= sim.config.lobbyJoinTimeoutTicks:
      sim.beginPlaying()
      sim.stepPlaying()
    else:
      inc sim.tickCount
      return
  of Playing:
    try:
      sim.stepPlaying()
    except LuxGuardError as error:
      sim.stopDetail = error.msg.truncateRunes(MaxFallbackDetailRunes)
      sim.settle(erFault, erlSimFault)
  of GameOver:
    discard
  inc sim.tickCount

func episodeFinished*(sim: SimServer): bool =
  sim.phase == GameOver and sim.gameOverTick >= 0 and
    sim.tickCount - sim.gameOverTick >= sim.config.gameOverTicks

func gameHash*(sim: SimServer): uint64 =
  if sim.phase == Lobby:
    var hash = 0xCBF29CE484222325'u64
    hash.mixHash(-1)
    hash.mixHash(sim.tickCount)
    return hash
  sim.world.gameHash()

# ---------------------------------------------------------------------------
#  The per-seat observation
# ---------------------------------------------------------------------------

func layerChar(world: World, cell: int): char =
  case world.board.terrain[cell]
  of tEmpty: '.'
  of tWood: 'w'
  of tCoal: 'c'
  of tUranium: 'u'

proc terrainLayer(world: World): JsonNode =
  result = newJArray()
  for y in 0 ..< world.board.size:
    var row = newStringOfCap(world.board.size)
    for x in 0 ..< world.board.size:
      let cell = y * world.board.size + x
      if world.board.terrain[cell] != tEmpty and world.board.amount[cell] <= 0:
        row.add('.')
      else:
        row.add(layerChar(world, cell))
    result.add(%row)

proc cityLayer(world: World): JsonNode =
  result = newJArray()
  for y in 0 ..< world.board.size:
    var row = newStringOfCap(world.board.size)
    for x in 0 ..< world.board.size:
      let cell = y * world.board.size + x
      case world.cities.teamOfCell[cell]
      of 0: row.add('R')
      of 1: row.add('B')
      else: row.add('.')
    result.add(%row)

proc unitLayer(world: World): JsonNode =
  var glyphs = newSeq[char](world.board.cellCount())
  for i in 0 ..< glyphs.len:
    glyphs[i] = '.'
  for unit in world.units.list:
    let want =
      if unit.team == Red:
        (if unit.kind == ukWorker: 'r' else: 'R')
      else:
        (if unit.kind == ukWorker: 'b' else: 'B')
    if glyphs[unit.cell] == '.':
      glyphs[unit.cell] = want
    elif glyphs[unit.cell] != want:
      glyphs[unit.cell] = '*'
    else:
      glyphs[unit.cell] = '*'
  result = newJArray()
  for y in 0 ..< world.board.size:
    var row = newStringOfCap(world.board.size)
    for x in 0 ..< world.board.size:
      row.add(glyphs[y * world.board.size + x])
    result.add(%row)

proc resourceBlock(world: World, kind: Terrain, seat: int): JsonNode =
  var
    tiles = 0
    total = 0
    yours = 0
    theirs = 0
  let half = world.board.size div 2
  for cell in 0 ..< world.board.cellCount():
    if world.board.terrain[cell] != kind or world.board.amount[cell] <= 0:
      continue
    inc tiles
    total += world.board.amount[cell]
    if world.board.cellX(cell) < half:
      if seat == 0: yours += world.board.amount[cell]
      else: theirs += world.board.amount[cell]
    else:
      if seat == 0: theirs += world.board.amount[cell]
      else: yours += world.board.amount[cell]
  %*{
    "tiles_left": tiles,
    "amount_left": total,
    "yours": yours,
    "theirs": theirs,
    "researched": world.researchPoints[seat] >= researchNeeded(kind)
  }

proc richestTiles(world: World): JsonNode =
  var picks: seq[tuple[amount, cell: int]] = @[]
  for cell in 0 ..< world.board.cellCount():
    if world.board.terrain[cell] == tEmpty or world.board.amount[cell] <= 0:
      continue
    picks.add((world.board.amount[cell], cell))
  ## Selection sort down to MaxRichestTiles: bounded, allocation-free and
  ## deterministic (ties by lowest cell index, because the scan is ascending).
  result = newJArray()
  for _ in 0 ..< MaxRichestTiles:
    var best = -1
    for i, pick in picks:
      if best < 0 or pick.amount > picks[best].amount:
        best = i
    if best < 0:
      break
    let pick = picks[best]
    picks.delete(best)
    result.add(%*{
      "kind": $world.board.terrain[pick.cell],
      "cell": [world.board.cellX(pick.cell), world.board.cellY(pick.cell)],
      "amount": pick.amount
    })

proc cityListJson(world: World, seat: int): tuple[list: JsonNode, omitted: int] =
  var indexes: seq[int] = @[]
  for i, city in world.cities.list:
    if ord(city.team) == seat:
      indexes.add(i)
  ## Largest first, ties by lowest city id (the list is already id-ordered).
  for a in 0 ..< indexes.len:
    for b in a + 1 ..< indexes.len:
      if world.cities.list[indexes[b]].cells.len >
          world.cities.list[indexes[a]].cells.len:
        swap(indexes[a], indexes[b])
  result.list = newJArray()
  result.omitted = max(0, indexes.len - MaxObservedCities)
  let nightTurnsLeft = max(1, world.nightLength())
  for position, index in indexes:
    if position >= MaxObservedCities:
      break
    let city = world.cities.list[index]
    let bill = city.upkeep(world.board, world.config.cityUpkeepPerTile,
      world.config.cityAdjacencyDiscount)
    var cells = newJArray()
    for i, cell in city.cells:
      if i >= MaxObservedCells:
        break
      cells.add(%[world.board.cellX(cell), world.board.cellY(cell)])
    var entry = %*{
      "id": city.id,
      "tiles": city.cells.len,
      "fuel": city.fuel,
      "upkeep_per_night_turn": bill,
      "survives_tonight": city.fuel >= int64(bill * nightTurnsLeft),
      "turns_of_fuel": city.turnsOfFuel(world.board,
        world.config.cityUpkeepPerTile, world.config.cityAdjacencyDiscount),
      "cells": cells
    }
    if city.cells.len > MaxObservedCells:
      entry["cells_omitted"] = %(city.cells.len - MaxObservedCells)
    result.list.add(entry)

proc seatObservation*(
  sim: SimServer, seat: int, since: array[3, int64],
  builtCities, builtWorkers, builtCarts, lostTiles, lostUnits: int,
  howItWent: string
): JsonNode =
  ## Everything this seat may legitimately know. Lux Season 1 is a FULLY
  ## OBSERVABLE game and this port is too: both seats see the entire board,
  ## both sides' units and cities, both sides' fuel and research, every
  ## resource amount and every road level.
  ##
  ## HIDDEN, and this is the complete list: the opponent's DIRECTIVE (this
  ## turn's and every past turn's), the opponent's `note`, every seat's
  ## PLAYER_PROMPT and the identity of any policy, the episode SEED and the
  ## `mapRng` state, and any seat's fallback/latency statistics.
  let
    world = sim.world
    turn = world.turn
    night = world.isNight(turn)
  var yoursCargo: array[3, int]
  for unit in world.units.list:
    if ord(unit.team) != seat:
      continue
    yoursCargo[0] += unit.wood
    yoursCargo[1] += unit.coal
    yoursCargo[2] += unit.uranium
  let
    mine = cityListJson(world, seat)
    theirs = cityListJson(world, 1 - seat)
    tiles = [world.cities.tileCount(Red), world.cities.tileCount(Blue)]
  var yours = %*{
    "research": world.researchPoints[seat],
    "research_to_uranium":
      max(0, world.config.uraniumResearch - world.researchPoints[seat]),
    "city_tiles": world.cities.tileCount(Team(seat)),
    "cities": world.cities.cityCount(Team(seat)),
    "workers": world.units.countOf(Team(seat), ukWorker),
    "carts": world.units.countOf(Team(seat), ukCart),
    "unit_cap_headroom": max(0,
      world.cities.tileCount(Team(seat)) - world.units.countOf(Team(seat))),
    "cargo_carried": {
      "wood": yoursCargo[0], "coal": yoursCargo[1], "uranium": yoursCargo[2]},
    "city_list": mine.list,
    "gathered_since_last_directive": {
      "wood": since[0], "coal": since[1], "uranium": since[2]},
    "built_since_last_directive": {
      "city_tiles": builtCities, "workers": builtWorkers, "carts": builtCarts},
    "lost_since_last_directive": {
      "city_tiles": lostTiles, "units": lostUnits}
  }
  if mine.omitted > 0:
    yours["cities_omitted"] = %mine.omitted
  var opponent = %*{
    "research": world.researchPoints[1 - seat],
    "city_tiles": world.cities.tileCount(Team(1 - seat)),
    "cities": world.cities.cityCount(Team(1 - seat)),
    "workers": world.units.countOf(Team(1 - seat), ukWorker),
    "carts": world.units.countOf(Team(1 - seat), ukCart),
    "city_list": theirs.list
  }
  if theirs.omitted > 0:
    opponent["cities_omitted"] = %theirs.omitted
  let leader =
    if tiles[0] > tiles[1]: cogAlias(0)
    elif tiles[1] > tiles[0]: cogAlias(1)
    else: "tied"
  result = %*{
    "you": cogAlias(seat),
    "side": (if seat == 0: "left" else: "right"),
    "opponent": cogAlias(1 - seat),
    "turn": turn,
    "of": world.config.maxTurns,
    "directive_turn": sim.directiveIndex(turn),
    "of_directives": sim.directiveCount(),
    "phase": (if night: "night" else: "day"),
    "cycle": world.cycleOf(turn) + 1,
    "turns_to_dawn": world.turnsToDawn(turn),
    "turns_to_dusk": world.turnsToDusk(turn),
    "map": {
      "size": world.board.size,
      "terrain": terrainLayer(world),
      "cities": cityLayer(world),
      "units": unitLayer(world),
      "legend": {
        "terrain": ". empty, w wood, c coal, u uranium",
        "cities": ". none, R RED city tile, B BLUE city tile",
        "units": ". none, r RED worker, R RED cart, b BLUE worker, " &
          "B BLUE cart, * two or more"}
    },
    "resources": {
      "wood": resourceBlock(world, tWood, seat),
      "coal": resourceBlock(world, tCoal, seat),
      "uranium": resourceBlock(world, tUranium, seat),
      "richest": richestTiles(world)
    },
    "yours": yours,
    "theirs": opponent,
    "standing": {
      "city_tiles": [tiles[seat], tiles[1 - seat]],
      "leader": leader,
      "margin": abs(tiles[0] - tiles[1])
    },
    "how_it_went": howItWent.truncateRunes(MaxHowItWentRunes)
  }
  if sim.haveDirective[seat]:
    result["your_last_directive"] = sim.directive[seat].directiveJson()
  else:
    result["your_last_directive"] = newJNull()

# ---------------------------------------------------------------------------
#  Results
# ---------------------------------------------------------------------------

proc luxResultsJson*(sim: SimServer): string =
  ## EXACTLY the 27 keys of the manifest's `results_schema`, which is
  ## `additionalProperties: false`. Adding or removing a key means editing
  ## `coworld_manifest_template.json` and `tools/ci/docker_smoke.sh`'s
  ## expected-key set in the same commit; `tests/test_lux_manifest.nim`
  ## asserts the two agree in both directions.
  let standing =
    if sim.settled: sim.finalStanding else: sim.world.standing()
  let outcome =
    if sim.settled: sim.outcome else: scoring.settle(standing)
  var mined = newJArray()
  for seat in 0 .. 1:
    mined.add(%[sim.world.resourcesMined[seat][0],
      sim.world.resourcesMined[seat][1], sim.world.resourcesMined[seat][2]])
  var node = %*{
    "names": [sim.seats[0].name, sim.seats[1].name],
    "aliases": [cogAlias(0), cogAlias(1)],
    "scores": [outcome.scoreOf(0), outcome.scoreOf(1)],
    "win": [outcome.winOf(0), outcome.winOf(1)],
    "reason": $sim.reason,
    "endRule": $sim.endRule,
    "cityTiles": [standing.cityTiles[0], standing.cityTiles[1]],
    "units": [standing.units[0], standing.units[1]],
    "fuel": [standing.fuel[0], standing.fuel[1]],
    "research": [standing.research[0], standing.research[1]],
    "cityTilesBuilt": [sim.world.cityTilesBuilt[0], sim.world.cityTilesBuilt[1]],
    "cityTilesLost": [sim.world.cityTilesLost[0], sim.world.cityTilesLost[1]],
    "unitsBuilt": [sim.world.unitsBuilt[0], sim.world.unitsBuilt[1]],
    "unitsLost": [sim.world.unitsLost[0], sim.world.unitsLost[1]],
    "resourcesMined": mined,
    "nightsSurvived": [sim.world.nightsSurvived[0], sim.world.nightsSurvived[1]],
    "blockedMoves": [sim.world.blockedMoves[0], sim.world.blockedMoves[1]],
    "turnsPlayed": sim.world.turn,
    "mapSize": sim.config.mapSize,
    "seed": sim.config.seed,
    "policyKinds": [
      (if sim.seats[0].isLlm: "llm" else: "scripted"),
      (if sim.seats[1].isLlm: "llm" else: "scripted")],
    "llmTurns": [sim.llmTurns[0], sim.llmTurns[1]],
    "fallbackTurns": [sim.fallbackTurns[0], sim.fallbackTurns[1]],
    "directivesRejected": [
      sim.directivesRejected[0], sim.directivesRejected[1]],
    "deadSeats": [sim.seats[0].dead, sim.seats[1].dead],
    "stopDetail": sim.stopDetail.truncateRunes(MaxFallbackDetailRunes)
  }
  if outcome.winner < 0:
    node["winner"] = newJNull()
  else:
    node["winner"] = %outcome.winner
  $node

const ResultsKeys* = [
  "names", "aliases", "scores", "win", "winner", "reason", "endRule",
  "cityTiles", "units", "fuel", "research", "cityTilesBuilt", "cityTilesLost",
  "unitsBuilt", "unitsLost", "resourcesMined", "nightsSurvived",
  "blockedMoves", "turnsPlayed", "mapSize", "seed", "policyKinds", "llmTurns",
  "fallbackTurns", "directivesRejected", "deadSeats", "stopDetail"]
  ## The 27 keys, in the order §Server lists them.

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the whole results document, written once
  ## into the replay chat stream at episode end. Without it a spectator holding
  ## the bytes reads `results: {}`. The document is already valid JSON, so it
  ## is embedded verbatim rather than re-parsed: nothing on the path to the
  ## artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.luxResultsJson() & "}"
