## Spectator chrome strings: nothing in the starter's tests, in viewer_smoke.mjs
## or in the label manifest covers them, so the re-labelings are enumerated and
## enforced here.

import std/[strutils, unittest]

import helpers

const Forbidden = [
  "Lives", "LIVES", "Clstr", "flag", "heart", "paint", "hopper", "hill",
  "POV", "spray", "grenade", "med kit", "kill"]

const InheritedNames = ["#killfeed", "killfeed", "killMarkerTeam"]
  ## The two names the design note KEEPS: `#killfeed` is the inherited match
  ## feed's element id (kept in the note's own kept-list) and `killMarkerTeam`
  ## is a `chrome_common.js` alias, and that file is pinned byte-identical.
  ## Renaming either would be an edit to inherited chrome, which is the thing
  ## this suite exists to prevent — so they are excluded by NAME, not by
  ## loosening the vocabulary.

const Replacements = [
  "<span class=\"momentum-label\">CITY TILES</span>",
  "Waiting for first light&hellip;",
  "<div class=\"caption\" id=\"clock-caption\">Dawn of the first day</div>",
  "Replay hash mismatch — showing recorded directives",
  "<span>City tiles</span>",
]

proc codeOnly(source: string): string =
  ## Strip /* … */ and // … comments and <!-- … --> so the vocabulary check
  ## reads the SHIPPED STRINGS, not the commit history in the comments.
  var
    at = 0
    kept = ""
  while at < source.len:
    if source.continuesWith("/*", at):
      let stop = source.find("*/", at)
      at = if stop < 0: source.len else: stop + 2
    elif source.continuesWith("<!--", at):
      let stop = source.find("-->", at)
      at = if stop < 0: source.len else: stop + 3
    elif source.continuesWith("//", at) and
        (at == 0 or source[at - 1] notin {':', '/'}):
      let stop = source.find("\n", at)
      at = if stop < 0: source.len else: stop
    elif source.continuesWith("  ## ", at) or source.continuesWith("\n##", at):
      let stop = source.find("\n", at + 1)
      at = if stop < 0: source.len else: stop
    else:
      kept.add(source[at])
      inc at
  kept

suite "lux endcard labels":
  var page = codeOnly(readRepoFile("client/replay_broadcast.html"))
  for name in InheritedNames:
    page = page.replace(name, "")

  test "the forbidden paintbot vocabulary is gone from the shipped strings":
    for word in Forbidden:
      checkpoint(word)
      check word notin page

  test "each re-mapped string is present exactly once":
    let raw = readRepoFile("client/replay_broadcast.html")
    for replacement in Replacements:
      checkpoint(replacement)
      check raw.count(replacement) == 1

  test "the endcard header reads Side / City tiles / Units / Fuel / Research":
    let raw = readRepoFile("client/replay_broadcast.html")
    check "<span>Side</span>" in raw
    check "<span>City tiles</span>" in raw
    check "<span>Units</span>" in raw
    check "<span>Fuel</span>" in raw
    check "<span>Research</span>" in raw
    ## and the starter's own header is gone
    check "<span>K</span><span>D</span>" notin raw

  test "the spoilers button and the mismatch warning speak Lux":
    let raw = readRepoFile("client/replay_broadcast.html")
    check "nightfalls / cities lost / winner" in raw
    check "showing recorded directives" in raw
