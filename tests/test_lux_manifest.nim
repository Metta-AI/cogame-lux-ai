## Every manifest pin, plus the two-way agreement with the sim.

import std/[json, strutils, tables, unittest]

import lux/sim
import helpers

let manifest = parseJson(readRepoFile("coworld_manifest_template.json"))

suite "lux manifest":
  test "num_agents is 2 in EVERY variant's game_config and in the fixture":
    check manifest["variants"].len == 3
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt() == 2
      ## and NEVER at a variant's top level (CoworldVariant is
      ## additionalProperties: false and the platform reads only game_config)
      check not variant.hasKey("num_agents")
      for key, _ in variant:
        check key in ["id", "name", "description", "game_config"]
    check manifest["certification"]["game_config"]["num_agents"].getInt() == 2

  test "no game_config anywhere carries a literal tokens array":
    for variant in manifest["variants"]:
      check not variant["game_config"].hasKey("tokens")
    check not manifest["certification"]["game_config"].hasKey("tokens")
    ## while config_schema keeps REQUIRING it
    check "tokens" in manifest["game"]["config_schema"]["required"].to(seq[string])

  test "the four SEAT-COUNT invariants docker_smoke.sh cross-checks":
    let certification = manifest["certification"]
    check certification["game_config"]["num_agents"].getInt() == 2
    check certification["players"].len == 2
    check certification["game_config"]["players"].len == 2
    check readRepoFile("tools/ci/docker_smoke.sh").contains("SMOKE_SEATS:-2")

  test "every declared player occupies a certification slot":
    var declared: seq[string]
    for entry in manifest["player"]:
      declared.add(entry["id"].getStr())
    check declared.len == 2
    var seated: seq[string]
    for entry in manifest["certification"]["players"]:
      seated.add(entry["player_id"].getStr())
    for id in declared:
      check id in seated

  test "every array property in config_schema declares minItems and maxItems":
    for name, field in manifest["game"]["config_schema"]["properties"]:
      if field{"type"}.getStr() == "array":
        checkpoint(name)
        check field.hasKey("minItems")
        check field.hasKey("maxItems")

  test "the top-level shape the 0.1.42 upload contract wants":
    check manifest.hasKey("$schema")
    check manifest["tags"].len >= 3
    check manifest["episode_timeout_minutes"].getInt() == 20
    check not manifest["game"].hasKey("tags")
    check not manifest.hasKey("version")
    check not manifest["game"].hasKey("display_name")
    check not manifest.hasKey("replay_viewer")
    check manifest["game"]["description"].getStr().len > 40
    check manifest["game"]["owner"].getStr() == "daveey@softmax.com"
    check manifest["game"]["runnable"]["type"].getStr() == "game"
    check manifest["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"
    for variant in manifest["variants"]:
      check variant["description"].getStr().len > 20

  test "protocols carry BOTH player and global as {type,value} objects":
    for key in ["player", "global"]:
      let node = manifest["game"]["protocols"][key]
      check node["type"].getStr() == "text"
      check node["value"].getStr().len > 200

  test "docs.readme and all three pages are non-empty TEXT":
    check manifest["game"]["docs"]["readme"]["type"].getStr() == "text"
    check manifest["game"]["docs"]["readme"]["value"].getStr().len > 200
    let pages = manifest["game"]["docs"]["pages"]
    check pages.len == 3
    var ids: seq[string]
    for page in pages:
      ids.add(page["id"].getStr())
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 200
    check ids == @["rules.md", "protocol.md", "commanding.md"]

  test "player[].resources.limits.cpu is at least 1":
    for entry in manifest["player"]:
      check entry["resources"]["limits"]["cpu"].getStr() == "1"
      check entry.hasKey("id")
      check entry.hasKey("type")
      check entry.hasKey("name")
      check entry.hasKey("description")
      check entry.hasKey("run")
      check entry.hasKey("source_url")

  test "every variant's wallClockBudgetSeconds is <= 660":
    for variant in manifest["variants"]:
      check variant["game_config"]["wallClockBudgetSeconds"].getInt() <= 660
    check manifest["certification"]["game_config"][
      "wallClockBudgetSeconds"].getInt() <= 660

  test "game.name equals the secret namespace and the compose-derived image":
    let name = manifest["game"]["name"].getStr()
    check name == "lux-ai"
    check manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/" & name & "/anthropic_api_key"
    let compose = readRepoFile("compose.yaml")
    check compose.contains("lux_ai:")
    check compose.contains("image: coworld-lux-ai:latest")
    check compose.contains("platform: linux/amd64")
    check compose.contains("network: host")
    check manifest["game"]["runnable"]["image"].getStr() == "{{LUX_AI_IMAGE}}"

  test "results_schema keys == luxResultsJson keys, in both directions":
    let
      schema = manifest["game"]["results_schema"]["properties"]
      produced = parseJson(initSimServer(fixtureConfig()).luxResultsJson())
    check schema.len == produced.len
    for key, _ in schema:
      check produced.hasKey(key)
    for key, _ in produced:
      check schema.hasKey(key)
    check manifest["game"]["results_schema"][
      "additionalProperties"].getBool() == false

  test "config_schema covers every field sim_config.update reads, and no other":
    ## Both directions: a knob the schema does not declare is a knob the
    ## platform cannot set, and a schema field the sim ignores is a lie.
    let source = readRepoFile("src/lux/sim_config.nim")
    var read: seq[string]
    var at = 0
    while true:
      let found = source.find("node{\"", at)
      if found < 0:
        break
      let stop = source.find("\"}", found + 6)
      read.add(source[found + 6 ..< stop])
      at = stop
    check read.len > 30
    let schema = manifest["game"]["config_schema"]["properties"]
    for key in read:
      checkpoint("sim reads " & key)
      check schema.hasKey(key)
    for key, _ in schema:
      if key == "tokens":
        continue                       ## runner-managed, read via config.tokens
      checkpoint("schema declares " & key)
      check key in read

  test "every variant's game_config constructs a valid GameConfig and generates the board it claims":
    for variant in manifest["variants"]:
      var config = defaultGameConfig()
      config.update(variant["game_config"])
      checkpoint(variant["id"].getStr())
      config.validate()
      let world = initWorld(config)
      check world.board.size == config.mapSize
      check world.board.mirrorSymmetric()
      var counts: array[4, int]
      for cell in 0 ..< world.board.cellCount():
        inc counts[ord(world.board.terrain[cell])]
      check counts[ord(tWood)] == 2 * config.woodClusters * 6
      check counts[ord(tCoal)] == 2 * config.coalClusters * 3
      check counts[ord(tUranium)] == 2 * config.uraniumClusters * 2
      check world.cities.tileCount(Red) == 1
      check world.cities.tileCount(Blue) == 1
    var certification = defaultGameConfig()
    certification.update(manifest["certification"]["game_config"])
    certification.validate()

  test "the certification fixture really plays a full episode with beats in it":
    ## The ecos scar: a replay shorter than the viewer soak reads as frozen.
    var config = defaultGameConfig()
    config.update(manifest["certification"]["game_config"])
    config.lobbyJoinTimeoutTicks = 2
    let game = scriptedEpisode(config)
    check game.reason == erComplete
    check game.endRule == erlFullTime
    check game.tickCount > 15 * 12          ## > 12 s of playback at ReplayFps
    check game.world.nightsSurvived[0] >= 6
    check game.world.researchPoints[0] >= 50 or
      game.world.researchPoints[1] >= 50
