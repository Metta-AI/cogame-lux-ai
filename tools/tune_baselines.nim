## The baseline tuner: a head-to-head sweep over the five scripted-baseline
## parameters, with a written-down objective and a `--check` mode CI re-runs.
##
##   nim r -d:release --path:src tools/tune_baselines.nim          # report
##   nim r -d:release --path:src tools/tune_baselines.nim --write  # rewrite the pick
##   nim r -d:release --path:src tools/tune_baselines.nim --check  # CI gate
##
## THE OBJECTIVE, in order:
##   1. `forester` must WIN the pinned duel seed and BOTH sides must survive all
##      nine nights there — a fixture of two dead islands is not a game.
##   2. then: the most seeds in the set where `forester` finishes ahead.
##   3. then: the most seeds that reach `full_time` (a replay that ends early is
##      a replay the viewer soak cannot ride out).
##   4. then: the most city tiles built by BOTH sides — a filler that never
##      builds is not an opponent.
##
## The grid is deliberately small (a few hundred episodes, a couple of seconds
## in release) so `--check` is cheap enough to run on every push.

import std/[json, os, strformat, strutils]

import lux/sim

const
  PinnedSeed = 1734029581
  Seeds = [PinnedSeed, 42, 7, 99, 1234]
  TuningPath = "tools/ci/baseline_tuning.json"

type Outcome = object
  tiles: array[2, int]
  nights: array[2, int]
  rule: EndRule

proc play(seed: int, tuning: BaselineTuning): Outcome =
  var config = defaultGameConfig()
  config.seed = seed
  config.lobbyJoinTimeoutTicks = 2
  var game = initSimServer(config)
  game.seats[0].joined = true
  game.seats[1].joined = true
  game.world.eventLoggingEnabled = false
  var lastDirective = -1
  while not game.episodeFinished():
    if game.phase == Playing and game.isDirectiveTurn(game.world.turn) and
        game.world.turn != lastDirective:
      lastDirective = game.world.turn
      game.setDirective(0, scriptedDirective(game.world, blForester, 0, tuning))
      game.setDirective(1, scriptedDirective(game.world, blProspector, 1, tuning))
    game.step()
  result.tiles = game.finalStanding.cityTiles
  result.nights = game.world.nightsSurvived
  result.rule = game.endRule

proc score(tuning: BaselineTuning): tuple[ok: bool, key: array[4, int]] =
  var
    wins = 0
    full = 0
    tiles = 0
  let pinned = play(PinnedSeed, tuning)
  result.ok = pinned.tiles[0] > pinned.tiles[1] and
    pinned.nights[0] >= 9 and pinned.nights[1] >= 9 and
    pinned.rule == erlFullTime
  for seed in Seeds:
    let outcome = play(seed, tuning)
    if outcome.tiles[0] > outcome.tiles[1]:
      inc wins
    if outcome.rule == erlFullTime:
      inc full
    tiles += outcome.tiles[0] + outcome.tiles[1]
  result.key = [(if result.ok: 1 else: 0), wins, full, tiles]

proc better(a, b: array[4, int]): bool =
  for i in 0 .. 3:
    if a[i] != b[i]:
      return a[i] > b[i]
  false

proc sweep(): tuple[best: BaselineTuning, key: array[4, int]] =
  result.key = [-1, -1, -1, -1]
  for foresterWorkers in [6, 7, 8]:
    for foresterFuelNights in [14, 16, 18, 20]:
      for prospectorEarlyWorkers in [6, 8]:
        for prospectorSeedTiles in [6, 8]:
          let tuning = BaselineTuning(
            foresterWorkers: foresterWorkers,
            foresterFuelNights: foresterFuelNights,
            prospectorEarlyWorkers: prospectorEarlyWorkers,
            prospectorLateWorkers: ProspectorLateWorkers,
            prospectorSeedTiles: prospectorSeedTiles)
          let scored = tuning.score()
          if better(scored.key, result.key):
            result.key = scored.key
            result.best = tuning

proc toJson(tuning: BaselineTuning): JsonNode =
  %*{
    "note": "The pick from tools/tune_baselines.nim. Regenerate with " &
      "`nim r -d:release --path:src tools/tune_baselines.nim --write`; " &
      "CI re-runs the sweep with --check.",
    "objective": "forester must WIN the pinned duel seed and BOTH sides must " &
      "survive all nine nights there; among the survivors, maximise forester " &
      "wins across the seed set, then full_time endings, then total city " &
      "tiles built by both sides (a filler that never builds is not an " &
      "opponent).",
    "seeds": Seeds,
    "foresterWorkers": tuning.foresterWorkers,
    "foresterFuelNights": tuning.foresterFuelNights,
    "prospectorEarlyWorkers": tuning.prospectorEarlyWorkers,
    "prospectorLateWorkers": tuning.prospectorLateWorkers,
    "prospectorSeedTiles": tuning.prospectorSeedTiles
  }

when isMainModule:
  let
    mode = if paramCount() >= 1: paramStr(1) else: ""
    picked = sweep()
  echo &"pick: workers={picked.best.foresterWorkers} " &
    &"fuelNights={picked.best.foresterFuelNights} " &
    &"prospectorEarly={picked.best.prospectorEarlyWorkers} " &
    &"prospectorLate={picked.best.prospectorLateWorkers} " &
    &"seedTiles={picked.best.prospectorSeedTiles}  key={picked.key}"
  if mode == "--write":
    writeFile(TuningPath, picked.best.toJson().pretty() & "\n")
    echo "wrote ", TuningPath
  elif mode == "--check":
    let stored = parseJson(readFile(TuningPath))
    var failures: seq[string] = @[]
    for key, value in picked.best.toJson():
      if key in ["note", "objective"]:
        continue
      if stored{key} != value:
        failures.add(key & ": shipped " & $stored{key} & ", sweep picked " & $value)
    if failures.len > 0:
      echo "tune_baselines --check FAILED:\n  ", failures.join("\n  ")
      quit(1)
    ## The shipped DEFAULTS must equal the file too, or the file is decoration.
    let shipped = defaultTuning()
    doAssert shipped.foresterWorkers == stored["foresterWorkers"].getInt()
    doAssert shipped.foresterFuelNights == stored["foresterFuelNights"].getInt()
    doAssert shipped.prospectorEarlyWorkers ==
      stored["prospectorEarlyWorkers"].getInt()
    doAssert shipped.prospectorLateWorkers ==
      stored["prospectorLateWorkers"].getInt()
    doAssert shipped.prospectorSeedTiles == stored["prospectorSeedTiles"].getInt()
    echo "tune_baselines --check ok"
