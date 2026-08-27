## Version discipline: the GameVersion changelog, and every committed fixture
## carrying the current version.

import std/[os, strutils, unittest]

import lux/[replays, sim]
import helpers

suite "lux gameversion":
  test "GameVersion is set and carries a prepend-only changelog headline":
    check GameVersion.len > 0
    let source = readRepoFile("src/lux/sim_types.nim")
    let at = source.find("GameVersion* =")
    check at > 0
    let comment = source[at .. min(source.len - 1, at + 900)]
    check "GV" & GameVersion & " (" in comment
    check "prepend-only" in comment.toLowerAscii() or
      "PREPEND-ONLY" in comment

  test "the replay spec pins the current game name and version":
    check LuxReplaySpec.gameName == GameName
    check LuxReplaySpec.gameVersion == GameVersion
    check LuxReplaySpec.magic == "COWLDLUX"
    check GameName == "lux-ai"

  test "every committed .replay fixture carries the current GameVersion":
    ## The starter's sweep over tests/, kept. There are no committed fixtures
    ## today (every replay this repo tests is written by the test itself, from
    ## the CURRENT rules, which is strictly stronger) — the sweep exists so the
    ## day one is added it cannot go stale.
    var found = 0
    for path in walkDirRec(repoRoot() / "tests"):
      if not path.endsWith(".replay"):
        continue
      inc found
      let data = parseLuxReplay(readFile(path))
      checkpoint(path)
      check data.gameVersion == GameVersion
      check data.gameName == GameName
    check found >= 0

  test "tools/ci/check_gameversion.sh is present and executable":
    let path = repoRoot() / "tools/ci/check_gameversion.sh"
    check fileExists(path)
    check fpUserExec in path.getFilePermissions()

  test "the executable bits coworld build and ci.yml hard-require":
    for path in ["tools/build_replay_viewer.sh", "tools/ci/docker_smoke.sh"]:
      let full = repoRoot() / path
      checkpoint(path)
      check fileExists(full)
      check fpUserExec in full.getFilePermissions()
