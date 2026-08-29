## Version discipline: the GameVersion changelog, and every committed fixture
## carrying the current version.

import std/[os, osproc, strutils, unittest]

import lux/[replays, sim]
import helpers

const GvScript = "tools/ci/check_gameversion.sh"

type GvEntry = tuple[version, rule: string]

proc gvGit(repo, args: string) =
  ## A git command in the throwaway fixture repo. Identity, signing and hooks
  ## are neutralised per call: the fixture must not inherit whatever the
  ## developer's global git config does, and `commit.gpgsign = true` on a
  ## machine with no usable key otherwise aborts the commit mid-test.
  let (output, code) = execCmdEx(
    "git -c user.email=t@example.com -c user.name=t -c init.defaultBranch=main" &
      " -c commit.gpgsign=false -c core.hooksPath=/nonexistent-hooks " & args,
    workingDir = repo)
  if code != 0:
    raise newException(OSError, "git " & args & " failed:\n" & output)

proc gvSimTypes(repo, version: string, entries: seq[GvEntry]) =
  ## A minimal sim_types.nim at the SAME path the real one lives at, in the
  ## same prepend-only changelog shape the script parses: newest entry first,
  ## `##`-separated, each headline wrapped across two lines.
  createDir(repo / "src" / "lux")
  var body = "const\n  GameVersion* = \"" & version & "\"\n" &
    "    ## PREPEND-ONLY changelog in the `GVnn (rule): HEADLINE` shape.\n"
  for e in entries:
    body.add("    ##\n    ## GV" & e.version & " (" & e.rule & "): headline " &
      "for the " & e.rule & " rules, wrapped across\n    ## two lines to " &
      "exercise the continuation the real changelog uses.\n")
  body.add("\n  GameName* = \"lux-ai\"\n")
  writeFile(repo / "src" / "lux" / "sim_types.nim", body)

proc gvRun(repo: string, args: varargs[string]):
    tuple[output: string, exitCode: int] =
  ## Run the script under test, by absolute path, with `repo` as its cwd.
  ## Variadic on purpose: the ONE-argument form is what ci.yml and AGENTS.md
  ## actually invoke, and it is only covered if a test can express it.
  var cmd = quoteShell(repoRoot() / GvScript)
  for a in args:
    cmd.add(" " & quoteShell(a))
  execCmdEx(cmd, workingDir = repo)

proc gvCommit(repo, version: string, entries: seq[GvEntry], message: string) =
  gvSimTypes(repo, version, entries)
  gvGit(repo, "add -A")
  gvGit(repo, "commit -q -m " & quoteShell(message))

proc gvFixturePath(): string =
  ## Named separately from the build so the caller can arm its cleanup BEFORE
  ## construction starts; a raise inside the build would otherwise leak the
  ## directory, and the pid-keyed name means no later run reclaims it.
  getTempDir() / ("lux_gv_fixture_" & $getCurrentProcessId())

proc gvBuildFixture(result: string) =
  ## A throwaway repo with three claims on the version number:
  ##   v9      GV9  "first"      the base
  ##   v10     GV10 "second"     a clean bump on top of it
  ##   collide GV9  "different"  a SECOND branch spending GV9 on another rule
  ##
  ## 9 and 10 rather than 1 and 2 on purpose: they pin that the comparison is
  ## NUMERIC (lexically "10" sorts below "9") and that looking up GV9 does not
  ## match the GV10 entry on a prefix. v10 carries two entries, which is what
  ## exercises the scan's entry terminator -- the real file grows a second
  ## entry at the first bump, and nothing else here would cover that.
  removeDir(result)
  createDir(result)
  gvGit(result, "init -q .")
  gvCommit(result, "9", @[("9", "first")], "base")
  gvGit(result, "branch -q v9")
  gvCommit(result, "10", @[("10", "second"), ("9", "first")], "bump")
  gvGit(result, "branch -q v10")
  gvGit(result, "checkout -q -b collide v9")
  gvCommit(result, "9", @[("9", "different")], "collide")

proc gvConstFile(): string =
  ## The path the script says it reads. This is the value that rotted: the
  ## script arrived from the starter byte-for-byte, naming the starter's own
  ## `src/ctf/sim_types.nim`.
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
      check "unchanged from the base" in output
      # Keyed on the version the SCRIPT reports, which it reads from COMMITTED
      # content -- not on the compiled-in `GameVersion`, which is read from the
      # working tree and diverges from it for the whole window between editing
      # the const and committing it. That window is the documented bump flow,
      # and coupling to it would make this the one test that goes red mid-bump.
      check " = GV" in output
      let reported = output.split(" = GV")[1].split(' ')[0]
      check ("GV" & reported & " (") in output
      check "GameVersion* =" notin output

  test "check_gameversion.sh passes a clean bump and catches every drift":
    ## Every verdict, against a throwaway repo this test builds. Hermetic: it
    ## needs the `git` binary but none of this repo's history, so it still
    ## covers CONST_FILE even from an exported tree with no .git.
    let repo = gvFixturePath()
    try:
      gvBuildFixture(repo)
      block sameNumberSameRule:
        let (output, code) = gvRun(repo, "v9", "v9")
        checkpoint(output)
        check code == 0
        check "no rule change claimed" in output

      block cleanBump:
        let (output, code) = gvRun(repo, "v9", "v10")
        checkpoint(output)
        check code == 0
        check "GV10 is above the base's GV9" in output

      block sameNumberDifferentRule:
        # The collision the script exists for: two branches, one number, two
        # rules.
        let (output, code) = gvRun(repo, "v9", "collide")
        checkpoint(output)
        check code == 1
        check "already spent" in output

      block behindTheBase:
        # Also pins that the compare is numeric: lexically "9" > "10".
        let (output, code) = gvRun(repo, "v10", "v9")
        checkpoint(output)
        check code == 1
        check "BELOW the base's GV10" in output

      block theOneArgumentFormCiAndAgentsMdUse:
        # ci.yml and AGENTS.md both invoke the script with ONE argument and let
        # the head default to HEAD. Nothing else here exercises that default,
        # and getting it wrong (defaulting to $BASE, say) makes every real
        # invocation a self-compare that passes on every collision -- the gate
        # failing OPEN, silently, which is the failure this script exists to end.
        gvGit(repo, "checkout -q collide")
        let (output, code) = gvRun(repo, "v9")
        checkpoint(output)
        check code == 1
        check "already spent" in output

      block twoEntriesClaimingOneNumber:
        # A merge resolved by keeping BOTH entries, the base's left on top.
        # Reading only the first match would hand back the base's headline for
        # both refs, compare equal, and wave the collision through.
        gvGit(repo, "checkout -q -b twoentries v9")
        gvCommit(repo, "9", @[("9", "first"), ("9", "different")], "two entries")
        let (output, code) = gvRun(repo, "v9", "twoentries")
        checkpoint(output)
        check code == 1
        check "two changelog entries claim the same GameVersion" in output

      block aBareBlankLineInsideTheBlock:
        # Nim accepts a blank line in the doc comment. It must not read as the
        # end of the changelog, or a valid entry below it goes invisible and
        # every PR fails on something the author cannot fix from their branch.
        gvGit(repo, "checkout -q -b blankline v9")
        writeFile(repo / "src" / "lux" / "sim_types.nim",
          "const\n  GameVersion* = \"9\"\n    ## preamble.\n\n" &
          "    ## GV9 (first): a headline below a bare blank line.\n")
        gvGit(repo, "add -A")
        gvGit(repo, "commit -q -m blankline")
        let (output, code) = gvRun(repo, "v9", "blankline")
        checkpoint(output)
        check "GV9 (first): a headline below a bare blank line." in output
        check "changelog entry" notin output

      block aSecondQuotedNumberOnTheDeclarationLine:
        # `grep -o` prints EVERY match on the line, not just the first, so an
        # inline `## was "8"` makes the version a TWO-LINE string that flows
        # into awk, into the numeric comparisons and into the operator's error
        # text. Nim accepts a trailing comment there, so nothing forbids it.
        gvGit(repo, "checkout -q -b trailing v9")
        writeFile(repo / "src" / "lux" / "sim_types.nim",
          "const\n  GameVersion* = \"9\"  ## was \"8\"\n" &
          "    ## GV9 (first): a headline after a second quoted number.\n")
        gvGit(repo, "add -A")
        gvGit(repo, "commit -q -m trailing")
        let (output, code) = gvRun(repo, "v9", "trailing")
        checkpoint(output)
        check code == 1              # the headline differs: a real collision
        check "= GV9 \u2014" in output   # the version is exactly "9", one line
        check "awk:" notin output

      block noChangelogEntryForTheNumber:
        # A bump with no headline leaves nothing to diff, and would sail
        # through on the number alone. Refusing beats passing blind.
        gvGit(repo, "checkout -q -b orphan v10")
        writeFile(repo / "src" / "lux" / "sim_types.nim",
          "const\n  GameVersion* = \"11\"\n    ## GV10 (second): stale.\n")
        gvGit(repo, "add -A")
        gvGit(repo, "commit -q -m orphan")
        let (output, code) = gvRun(repo, "v10", "orphan")
        checkpoint(output)
        check code == 1
        check "changelog entry" in output

      block aRefThatDoesNotResolve:
        # `git show` reports a bad ref and a missing path identically once its
        # stderr is dropped; the operator needs to know which one happened.
        let (output, code) = gvRun(repo, "no-such-ref", "v9")
        checkpoint(output)
        check code == 1
        check "does not resolve" in output
    finally:
      removeDir(repo)

  test "the executable bits coworld build and ci.yml hard-require":
    for path in ["tools/build_replay_viewer.sh", "tools/ci/docker_smoke.sh"]:
      let full = repoRoot() / path
      checkpoint(path)
      check fileExists(full)
      check fpUserExec in full.getFilePermissions()
