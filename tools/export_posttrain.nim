## Export complete native Lux games with each seat's hosted observation.

import std/[json, os, osproc, strutils]
import lux/[sim, decide, llm]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: lux-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update(variantConfig)
    config.validate()
    var game = initSimServer(config)
    game.beginPlaying()
    var progress: DecisionEngine
    var rows: seq[string]
    while game.phase == Playing:
      if game.isDirectiveTurn(game.world.turn):
        var decisions: array[2, Directive]
        for seat in 0 .. 1:
          let story = progress.snapshot(game, seat)
          let observation = game.seatObservation(seat, story.since,
            story.cities, story.workers, story.carts, story.lostTiles,
            story.lostUnits, story.story)
          let baseline = if (seat + seed) mod 2 == 0:
            blForester else: blProspector
          let teacher = scriptedDirective(game.world, baseline, seat)
          let completion = directiveJson(teacher)
          let accepted = parseDirective(completion, game.directive[seat],
            game.config.mapSize)
          doAssert accepted.repaired == 0
          doAssert directiveJson(accepted) == completion
          decisions[seat] = accepted
          rows.add($(%*{
            "episode_id": "lux-ai-" & variant & "-" & $seed,
            "seed": "lux-ai-" & variant & "-" & $seed,
            "decision_id": rows.len,
            "prompt": [
              {"role": "system", "content": SystemPrompt},
              {"role": "user", "content": userMessage("", $observation)}
            ],
            "completion": [{"role": "assistant", "content": $completion}],
            "game": "lux-ai", "action_schema_revision": "lux-directive-v1"
          }))
        for seat in 0 .. 1:
          game.setDirective(seat, decisions[seat])
      game.step()
    doAssert game.reason == erComplete,
      "seed " & $seed & " ended " & $game.reason & "/" & $game.endRule &
      ": " & game.stopDetail
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    let results = parseJson(game.luxResultsJson())
    runs.add(%*{"seed": seed, "turns": game.world.turn,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "lux-ai", "variant": variant,
    "source_revision": revision, "teacher": "forester-and-prospector",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
