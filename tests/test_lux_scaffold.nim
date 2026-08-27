## The scaffold every later phase depends on: no unsubstituted placeholder, the
## policy set's shape, and the three workflows' input names.

import std/[json, strutils, unittest]

import helpers

const Scaffold = [
  ".github/workflows/ci.yml",
  ".github/workflows/coworld-release.yml",
  ".github/workflows/coworld-submit.yml",
  "tools/ci/docker_smoke.sh",
  "tools/ci/policies.json",
]

suite "lux scaffold":
  test "no unsubstituted <slug> / <IMAGE> / <SEATS> survives":
    for path in Scaffold:
      let source = readRepoFile(path)
      for placeholder in ["<slug>", "<IMAGE>", "<SEATS>"]:
        checkpoint(path & " " & placeholder)
        check placeholder notin source

  test "ci.yml carries the slug, the image and the jobs phase 20 gates on":
    let ci = readRepoFile(".github/workflows/ci.yml")
    check "SLUG: lux-ai" in ci
    check "IMAGE: coworld-lux-ai" in ci
    check "docker-smoke:" in ci
    check "wasm-viewer:" in ci
    check "tools/ci/docker_smoke.sh" in ci
    check "tools/build_replay_viewer.sh" in ci
    check "tools/ci/viewer_smoke.mjs" in ci
    check "SMOKE_REQUIRE_REPLAY_JSON: \"0\"" in ci   ## the replay is binary
    check "--soak 10" in ci
    check "--strict-text-bounds" in ci
    check "tools/wasm_replay_smoke.cjs" in ci
    check "renderer_fixture.html" in ci
    check "tune_baselines.nim --check" in ci

  test "the release and submit workflows expose the inputs phases 40/50 pass":
    let release = readRepoFile(".github/workflows/coworld-release.yml")
    for input in ["version:", "policies:", "put_secret:", "skip_certify:"]:
      checkpoint(input)
      check ("      " & input) in release
    check "release-result" in release
    check "player_id" in release or "\"player\"" in release
    check "--timeout-seconds 300" in release
    let submit = readRepoFile(".github/workflows/coworld-submit.yml")
    for input in ["player_id:", "policy:", "league_id:"]:
      checkpoint(input)
      check ("      " & input) in submit
    check "submit-result" in submit

  test "policies.json is the canonical set: two prompts, two scripted, one image":
    let policies = parseJson(readRepoFile("tools/ci/policies.json"))
    check policies.len == 4
    var prompts, scripted = 0
    for policy in policies:
      check policy["run"].getStr() == "/bin/lux-ai-player"
      check policy["name"].getStr().startsWith("lux-ai-")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 400
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check policy["env"]["PLAYER_SCRIPTED"].getStr() in
          ["forester", "prospector"]
      ## the LLM call is made by the GAME pod, so no policy carries a sidecar flag
      check not policy["env"].hasKey("USE_BEDROCK")
    check prompts == 2
    check scripted == 2
    ## champion #2 — the SECOND PLAYER_PROMPT entry — is owned by daveey-1
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check not policies[0].hasKey("player")
    ## and the two champion prompts really are different
    check policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
      policies[1]["env"]["PLAYER_PROMPT"].getStr()

  test "the docker smoke's seat cross-check agrees with the manifest":
    let smoke = readRepoFile("tools/ci/docker_smoke.sh")
    check "SMOKE_SEATS:-2" in smoke
    check "slug=\"${SMOKE_SLUG:-lux-ai}\"" in smoke
    check "/bin/${slug}" in smoke
    check "/bin/${slug}-player" in smoke
    let manifest = parseJson(readRepoFile("coworld_manifest_template.json"))
    check manifest["certification"]["game_config"]["num_agents"].getInt() == 2

  test "viewer_smoke.mjs is the VERBATIM template copy":
    let smoke = readRepoFile("tools/ci/viewer_smoke.mjs")
    check "data-replay-loaded" in smoke
    check "coworld-replay" in smoke
    check "playwright" in smoke.toLowerAscii()
    ## it takes NO substitutions, so the placeholder names must still be there
    check "--bundle <dir>" in smoke
    check "lux-ai" notin smoke

  test "the art pipeline is committed and reproducible":
    check readRepoFile("scripts/art/split_cog_sheet.py").len > 1000
    for name in ["red_worker", "red_cart", "blue_worker", "blue_cart"]:
      checkpoint(name)
      check readRepoFile("data/cogs/" & name & ".png").len > 1000
    check readRepoFile("scripts/art/source/cogs_sheet.png").len > 10_000
