## The two scripted baselines, both shipped as fillers. `forester` is ALSO the
## server-side per-turn fallback, the driver of a no-show or disconnected seat,
## the certification player and the published default.
##
## Both emit the SAME directive object an LLM does, through the SAME validator,
## and both are pure functions of the PUBLIC world state — which is what makes
## the bounded-orders test in `tests/test_lux_baselines.nim` meaningful.
## Neither ever writes a `note`: they are the sides that do not explain
## themselves.
##
## The five tuned numbers — `forester`'s worker target and its
## `foresterFuelNights * upkeep` starvation threshold, and `prospector`'s
## early/late worker targets and its seed-blob size — are the pick from
## `tools/tune_baselines.nim`'s head-to-head sweep, pinned in
## `tools/ci/baseline_tuning.json`. `tests/test_lux_baselines.nim` asserts the
## shipped defaults equal that file and `ci.yml` re-runs the sweep with
## `--check`.

import board, cities, directives, sim_state, sim_types

type
  Baseline* = enum
    blForester = "forester"
    blProspector = "prospector"

  BaselineTuning* = object
    ## The swept parameters. `tools/tune_baselines.nim` runs the head-to-head
    ## sweep and writes the pick to `tools/ci/baseline_tuning.json`;
    ## `tests/test_lux_baselines.nim` asserts the shipped defaults equal it and
    ## `ci.yml` re-runs the sweep with `--check`.
    foresterWorkers*: int
    foresterFuelNights*: int
    prospectorEarlyWorkers*: int
    prospectorLateWorkers*: int
    prospectorSeedTiles*: int

const
  ForesterWorkers* = 6
  ForesterFuelNights* = 18
  ProspectorEarlyWorkers* = 6
  ProspectorLateWorkers* = 10
  ProspectorSeedTiles* = 8

func defaultTuning*(): BaselineTuning =
  BaselineTuning(
    foresterWorkers: ForesterWorkers,
    foresterFuelNights: ForesterFuelNights,
    prospectorEarlyWorkers: ProspectorEarlyWorkers,
    prospectorLateWorkers: ProspectorLateWorkers,
    prospectorSeedTiles: ProspectorSeedTiles)

proc parseBaseline*(name: string): Baseline =
  ## Anything unrecognised is the published default — the starter's rule.
  for value in Baseline:
    if $value == name:
      return value
  blForester

func richestTileOfKind(world: World, seat: int, kind: Terrain): int =
  ## The richest tile of `kind` on this seat's half, ties by lowest cell index.
  result = -1
  var best = 0
  let half = world.board.size div 2
  for cell in 0 ..< world.board.cellCount():
    if world.board.terrain[cell] != kind or world.board.amount[cell] <= 0:
      continue
    let x = world.board.cellX(cell)
    if (seat == 0 and x >= half) or (seat == 1 and x < half):
      continue
    if world.board.amount[cell] > best:
      best = world.board.amount[cell]
      result = cell

proc foresterDirective*(
  world: World, seat: int, tuning = defaultTuning()
): Directive =
  ## The strong simple Lux opening, held all game: wood until coal is
  ## researched, expand unless a city is within eleven nights of starving.
  let team = Team(seat)
  result = defaultDirective()
  result.source = dsScripted
  result.note = ""
  var starving = false
  for city in world.cities.list:
    if city.team != team:
      continue
    let bill = city.upkeep(world.board, world.config.cityUpkeepPerTile,
      world.config.cityAdjacencyDiscount)
    if city.fuel < int64(tuning.foresterFuelNights * bill):
      starving = true
  result.stance = if starving: stFuel else: stExpand
  if world.researchPoints[seat] >= world.config.coalResearch:
    result.mine = [tCoal, tWood, tUranium]
    result.research = rtNone
  else:
    result.mine = [tWood, tCoal, tUranium]
    result.research = rtCoal
  result.build = boAuto
  result.workers = tuning.foresterWorkers
  result.carts = if world.cities.tileCount(team) >= 8: 1 else: 0
  result.night = npShelter
  # focus: the cell orthogonally adjacent to my largest city that is nearest a
  # wood tile with amount > 0, ties by lowest cell index.
  result.hasFocus = false
  let largest = world.cities.largestCityIndex(team)
  if largest >= 0:
    var woodCells: seq[int] = @[]
    for cell in 0 ..< world.board.cellCount():
      if world.board.terrain[cell] == tWood and world.board.amount[cell] > 0:
        woodCells.add(cell)
    if woodCells.len > 0:
      var blocked = newSeq[bool](world.board.cellCount())
      for cell in 0 ..< world.board.cellCount():
        let tileTeam = world.cities.teamOfCell[cell]
        blocked[cell] = tileTeam >= 0 and tileTeam != seat
      let field = bfsDistances(world.board, woodCells, blocked)
      var
        best = -1
        bestDistance = high(int)
      for tile in world.cities.list[largest].cells:
        for neighbour in world.board.orthogonal(tile):
          if world.cities.hasTile(neighbour):
            continue
          let distance = field[neighbour]
          if distance < 0:
            continue
          if distance < bestDistance:
            bestDistance = distance
            best = neighbour
      if best >= 0:
        result.hasFocus = true
        result.focusX = world.board.cellX(best)
        result.focusY = world.board.cellY(best)

proc prospectorDirective*(
  world: World, seat: int, tuning = defaultTuning()
): Directive =
  ## Deliberately different in SHAPE so the ladder gets a spread rather than
  ## two versions of one bot: it buys the fuel ladder early and pays for it in
  ## tiles. `forester` beats it at the pinned seed, which is a real bar for a
  ## champion to clear.
  result = defaultDirective()
  result.source = dsScripted
  result.note = ""
  let
    research = world.researchPoints[seat]
    tiles = world.cities.tileCount(Team(seat))
  var starving = false
  for city in world.cities.list:
    if city.team != Team(seat):
      continue
    let bill = city.upkeep(world.board, world.config.cityUpkeepPerTile,
      world.config.cityAdjacencyDiscount)
    if city.fuel < int64(tuning.foresterFuelNights * bill):
      starving = true
  if starving:
    ## The SAME night guard `forester` carries. Without it `prospector` plants
    ## its seed blob on an empty tank and is wiped out in night 1 on most
    ## seeds, which is a dead filler rather than a control. Documented in
    ## docs/RULES.md.
    result.stance = stFuel
    result.research =
      if world.researchPoints[seat] < world.config.uraniumResearch: rtUranium
      else: rtNone
    result.workers = tuning.prospectorEarlyWorkers
  elif research < world.config.uraniumResearch:
    ## The note's shape — "research until 200, then expand" — with one
    ## amendment the unit cap forces: a side that owns fewer than
    ## `prospectorSeedTiles` city tiles has nothing to research WITH (S1 caps
    ## units at city tiles, and a lone tile earns one point every ten turns, so
    ## 200 points is 2000 turns). It plants its seed blob first and buys the
    ## ladder from there. Documented in docs/RULES.md.
    result.stance = if tiles < tuning.prospectorSeedTiles: stExpand
                    else: stResearch
    result.research = rtUranium
    result.workers = tuning.prospectorEarlyWorkers
  else:
    result.stance = stExpand
    result.research = rtNone
    result.workers = tuning.prospectorLateWorkers
  if research >= world.config.uraniumResearch:
    result.mine = [tUranium, tCoal, tWood]
  elif research >= world.config.coalResearch:
    result.mine = [tCoal, tWood, tUranium]
  else:
    result.mine = [tWood, tCoal, tUranium]
  result.build = boAuto
  result.carts = 2
  result.night = npShelter
  result.hasFocus = false
  var kind = tWood
  if research >= world.config.uraniumResearch: kind = tUranium
  elif research >= world.config.coalResearch: kind = tCoal
  let cell = world.richestTileOfKind(seat, kind)
  if cell >= 0:
    result.hasFocus = true
    result.focusX = world.board.cellX(cell)
    result.focusY = world.board.cellY(cell)

proc scriptedDirective*(
  world: World, baseline: Baseline, seat: int, tuning = defaultTuning()
): Directive =
  ## The one entry point. The decision engine's fallback path calls THIS with
  ## `blForester`, so the fallback and the `forester` filler cannot drift —
  ## `tests/test_lux_baselines.nim` asserts they resolve to the same proc.
  case baseline
  of blForester: foresterDirective(world, seat, tuning)
  of blProspector: prospectorDirective(world, seat, tuning)
