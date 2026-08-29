## Version discipline: the GameVersion changelog, and every committed fixture
## carrying the current version.

import std/[os, osproc, strutils, unittest]

import lux/[replays, sim]
import helpers

const GvScript = "tools/ci/check_gameversion.sh"

proc gvGit(repo, args: string) =
  ## A git command in the throwaway fixture repo. Identity is passed per-call so
  ## the test does not depend on the runner having a global git config.
  let (output, code) = execCmdEx(
    "git -c user.email=t@example.com -c user.name=t -c init.defaultBranch=main " &
      args, workingDir = repo)
  if code != 0:
    raise newException(OSError, "git " & args & " failed:\n" & output)

proc gvSimTypes(repo, version, rule: string) =
  ## A minimal sim_types.nim at the SAME path the real one lives at, carrying
  ## the same prepend-only changelog shape the script parses.
  createDir(repo / "src" / "lux")
  writeFile(repo / "src" / "lux" / "sim_types.nim", """
const
  GameVersion* = "$1"
    ## PREPEND-ONLY changelog in the `GVnn (rule): HEADLINE` shape.
    ##
    ## GV$1 ($2): headline for the $2 rules, wrapped across two lines to
    ## exercise the continuation the real changelog uses.

  GameName* = "lux-ai"
""" % [version, rule])

proc gvRun(repo, base, head: string): tuple[output: string, exitCode: int] =
  ## Run the script under test, by absolute path, with `repo` as its cwd.
  execCmdEx(quoteShell(repoRoot() / GvScript) & " " & quoteShell(base) & " " &
    quoteShell(head), workingDir = repo)

proc gvCommit(repo, version, rule, message: string) =
  gvSimTypes(repo, version, rule)
  gvGit(repo, "add -A")
  gvGit(repo, "commit -q -m " & quoteShell(message))

proc gvFixtureRepo(): string =
  ## A throwaway repo with three claims on the version number:
  ##   v1      GV1 "first"      the base
  ##   v2      GV2 "second"     a clean bump on top of it
  ##   collide GV1 "different"  a SECOND branch spending GV1 on another rule
  result = getTempDir() / ("lux_gv_fixture_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  gvGit(result, "init -q .")
  gvCommit(result, "1", "first", "base")
  gvGit(result, "branch -q v1")
  gvCommit(result, "2", "second", "bump")
  gvGit(result, "branch -q v2")
  gvGit(result, "checkout -q -b collide v1")
  gvCommit(result, "1", "different", "collide")

proc gvConstFile(): string =
  ## The path the script says it reads. This is the value that rotted: the
  ## script arrived from the starter naming `src/ctf/sim_types.nim`.
  let script = readRepoFile(GvScript)
  const marker = "CONST_FILE=\""
  let at = script.find(marker)
  doAssert at > 0, "no CONST_FILE assignment in " & GvScript
  let rest = script[at + marker.len .. ^1]
  rest[0 ..< rest.find('"')]

proc gvInWorkTree(): bool =
  let (output, code) = execCmdEx("git rev-parse --is-inside-work-tree",
    workingDir = repoRoot())
  code == 0 and output.strip() == "true"

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
    let path = repoRoot() / GvScript
    check fileExists(path)
    check fpUserExec in path.getFilePermissions()

  test "check_gameversion.sh reads the file this repo actually keeps":
    ## The script is copied from the starter byte-for-byte, so the one thing in
    ## it that CANNOT survive the copy is the repo-specific path. It named
    ## `src/ctf/sim_types.nim` here, which made every run exit 1 on an
    ## unreadable file -- documented in AGENTS.md as THE version check, and
    ## never once working. Needs no git and no subprocess, so it holds even
    ## where the executing tests below cannot run.
    let constFile = gvConstFile()
    checkpoint("check_gameversion.sh reads " & constFile)
    check fileExists(repoRoot() / constFile)
    check constFile == "src/lux/sim_types.nim"

  test "check_gameversion.sh RUNS, and agrees with itself on this checkout":
    ## Executing it, not just stat-ing it: HEAD against HEAD must parse this
    ## repo's real declaration and its real changelog block and come back clean.
    if not gvInWorkTree():
      checkpoint("skipped: not a git work tree (no .git)")
      skip()
    else:
      let (output, code) = gvRun(repoRoot(), "HEAD", "HEAD")
      checkpoint(output)
      check code == 0
      check ("GV" & GameVersion & " unchanged") in output
      # The headline, not the declaration line: reading the declaration would
      # make the collision check below compare a string with itself.
      check ("GV" & GameVersion & " (") in output
      check "GameVersion* =" notin output

  test "check_gameversion.sh passes a clean bump and catches every drift":
    ## The four verdicts, against a throwaway repo this test builds. Hermetic:
    ## it needs the `git` binary but none of this repo's history, so it still
    ## covers the path above even from an exported tree.
    let repo = gvFixtureRepo()
    defer: removeDir(repo)

    block sameNumberSameRule:
      let (output, code) = gvRun(repo, "v1", "v1")
      checkpoint(output)
      check code == 0
      check "no rule change claimed" in output

    block cleanBump:
      let (output, code) = gvRun(repo, "v1", "v2")
      checkpoint(output)
      check code == 0
      check "GV2 is above the base's GV1" in output

    block sameNumberDifferentRule:
      # The collision the script exists for: two branches, one number, two rules.
      let (output, code) = gvRun(repo, "v1", "collide")
      checkpoint(output)
      check code == 1
      check "already spent" in output

    block behindTheBase:
      let (output, code) = gvRun(repo, "v2", "v1")
      checkpoint(output)
      check code == 1
      check "BELOW the base's GV2" in output

    block noChangelogEntryForTheNumber:
      # A bump with no headline leaves nothing to diff. Refusing beats passing
      # blind, which is what comparing two empty headlines would do.
      gvGit(repo, "checkout -q -b orphan v2")
      writeFile(repo / "src" / "lux" / "sim_types.nim",
        "const\n  GameVersion* = \"9\"\n    ## GV2 (second): stale headline.\n")
      gvGit(repo, "add -A")
      gvGit(repo, "commit -q -m orphan")
      let (output, code) = gvRun(repo, "v2", "orphan")
      checkpoint(output)
      check code == 1
      check "changelog entry" in output

  test "the executable bits coworld build and ci.yml hard-require":
    for path in ["tools/build_replay_viewer.sh", "tools/ci/docker_smoke.sh"]:
      let full = repoRoot() / path
      checkpoint(path)
      check fileExists(full)
      check fpUserExec in full.getFilePermissions()
