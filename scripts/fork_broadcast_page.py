#!/usr/bin/env python3
"""Fork coworld-ctf's broadcast page into cogame-lux-ai's.

`client/replay_broadcast.html` is the STARTER'S PAGE, not a lookalike: this
script takes the inherited page verbatim, deletes exactly the elements and the
ctf-specific JS regions the design note lists as removed, and appends the
lux-ai game block after the documented splice banner. Everything the note keeps
— `relayout()`, the transport, the endcard, the locker-room loader, `?embed=1`,
the `.tiny` density system, the whole `#transport` / `#scrub` markup — is
inherited untouched.

It exists so the fork is REPRODUCIBLE and reviewable: run it against the
starter mount and diff the result against the committed page.

    python3 scripts/fork_broadcast_page.py \
        /workspace/starters/coworld-ctf client/replay_broadcast.html

The committed page is the output; CI does not run this.
"""

from __future__ import annotations

import os
import sys

# (first line, last line) — inclusive, 1-indexed, in the STARTER's file.
# Each region is a contiguous block whose only consumers are the elements the
# design note removes.
DELETE_REGIONS = [
    # 1641-1658 is the EYES prose; 1659-1672 is the COG_BASE path story, which
    # the LOCKER ROOM also depends on, so 1659-1675 stays and only the
    # billboard art either side of it goes.
    (1641, 1658, "the EYES PiP prose (no per-unit point of view here)"),
    (1676, 1703, "the EYES PiP billboard art and its trim/pose math"),
    (1943, 1955, "the flag icon svg (nothing in Lux can be captured)"),
    (2087, 2116, "ingestFpMap — the FPV tactical-map silhouette"),
    (2117, 2346, "the ctf scorebug internals (squad pips, lives, flags)"),
    (2347, 3466, "renderPov + the whole first-person PIP pipeline"),
    (3474, 3554, "applyEvent + onKill/onSteal/onReturn/onCapture"),
    (3618, 3921, "the ctf endcard (hearts, lives, K/D/Clstr/Cap columns)"),
    (4002, 4275, "the #viewpanel zoom cluster and minimap wiring"),
]

# Markup blocks deleted from <body>, by exact opening/closing anchor.
DELETE_MARKUP = [
    # The closers are NEWLINE-ANCHORED: "      </div>" contains "    </div>",
    # so an unanchored search closes the block at the first NESTED div and
    # leaves the rest of the cluster behind.
    ('    <div id="viewpanel">', "\n    </div>\n"),
    ('    <div id="povBadge">', "\n"),
    ('    <div id="fpv">', "\n    </div>\n"),
]

# CSS rules deleted with the elements they styled. Each entry is a selector
# prefix; every rule block whose selector line starts with it goes.
DELETE_CSS_PREFIXES = [
    "#viewpanel", "#minimap", "#zoombar", "#zoom-", ".mm-cap", ".zbtn",
    "#fpv", ".fpv-", "#povBadge",
    ".hillchip", ".hcap", ".flagicon", ".lives-num", ".lives-label",
    ".squad-pip", ".squad", ".pb-tags", "#pb-regime", ".ec-heart",
    "#endcard .ec-heart", ".plate.leader .lives-num",
    "#stage.beat-active .plate.leader .lives-num",
    "#stage.tiny .plate .squad-pip", "body[data-noviewpanel]",
    ".plate .perk-icos", ".plate .perk-ico", ".plate .hcap",
    ".plate.side-r .squad", ".plate .squad",
    ".beat-marker.kill", ".beat-marker.steal", ".beat-marker.return",
    ".beat-marker.capture", ".beat-marker.hillflip", ".beat-marker.hillhold",
    ".beat-marker.tagout", ".beat-marker.gamestart", ".beat-marker.gameover",
    ".perk", ".handicap",
    "@keyframes flagflip", ".feed-row.flagkill", ".flagicon",
]

# Spectator-chrome vocabulary the design note re-maps. Applied to the whole
# inherited page after the deletions.
RELABEL = [
    ("<title>Ctf — Broadcast Replay</title>",
     "<title>Lux AI — Broadcast Replay</title>"),
    ("window.CtfStaticReplay", "window.LuxStaticReplay"),
    ('<span class="momentum-label">LIVES LEAD</span>',
     '<span class="momentum-label">CITY TILES</span>'),
    ("Filling hoppers with fresh paint&hellip;", "Waiting for first light&hellip;"),
    ('<div class="caption" id="clock-caption">In the locker room</div>',
     '<div class="caption" id="clock-caption">Dawn of the first day</div>'),
    ("Replay hash mismatch — showing recorded inputs",
     "Replay hash mismatch — showing recorded directives"),
    ("Spoilers: kills / flag story / winner on the timeline ahead of the playhead (o)",
     "Spoilers: nightfalls / cities lost / winner on the timeline ahead of the playhead (o)"),
    ("Bot locker room &middot; Loading replay",
     "Cog depot &middot; Loading replay"),
    ("""      'Filling hoppers with fresh paint\u2026',
      'Pump check: one, two. One, two\u2026',
      'Polishing visors to a mirror shine\u2026',
      'Shaking the paint pods awake\u2026',
      'Squats. Even robots warm up\u2026',
      'Topping off the CO\u2082\u2026',
      'Chalking up the wheels\u2026',
      'Reviewing the game plan\u2026'""",
     """      'Sharpening the axes\u2026',
      'Counting the wood on the near belt\u2026',
      'Checking the night bill, tile by tile\u2026',
      'Greasing the cart wheels\u2026',
      'Squats. Even robots warm up\u2026',
      'Reading the research board\u2026',
      'Chalking the island grid\u2026',
      'Waiting for the sun\u2026'"""),
]

# Calls into deleted regions, neutralised where the inherited frame loop makes
# them. The lux block installs its own replacements through LUX_CTX.
PATCH = [
    ("    renderScorebug(s);\n    renderClock(s);\n"
     "    renderTransport(s);\n    renderPov(s);\n    renderMismatch(s);\n",
     "    renderClock(s);\n    renderTransport(s);\n    renderMismatch(s);\n"),
    ("    if (s.events && s.events.length && !jumped) {\n"
     "      for (var i = 0; i < s.events.length; i++) applyEvent(s.events[i], s);\n"
     "    }\n",
     "    if (s.events && s.events.length && !jumped) {\n"
     "      for (var i = 0; i < s.events.length; i++) {\n"
     "        if (window.LuxChrome) window.LuxChrome.event(s.events[i], s, LUX_CTX);\n"
     "      }\n"
     "    }\n"),
    ("    ingestLeadSeries(s);\n    ingestFpMap(s);\n    ingestLullSpans(s);\n"
     "    ingestBeats(s);\n    ingestCapHearts(s);\n    recordMomentum(s);\n",
     "    ingestLeadSeries(s);\n    ingestLullSpans(s);\n"
     "    ingestBeats(s);\n    recordMomentum(s);\n"),
    ("    if (s.ph === 'gameover') { renderEndcard(s); if (s.over) setVerdict(s.over); }\n"
     "    else { $('endcard').classList.remove('on'); }\n",
     "    if (s.ph === 'gameover') {\n"
     "      if (window.LuxChrome) window.LuxChrome.endcard(s, LUX_CTX);\n"
     "      if (s.over) setVerdict(s.over);\n"
     "    } else { $('endcard').classList.remove('on'); }\n"),
    ("    // PAINTBALL additions run last, over the classic chrome's own render.\n"
     "    if (PB_MODE && window.PaintballChrome) window.PaintballChrome.frame(s, PB_CTX, jumped);\n",
     "    // LUX-AI additions run last, over the inherited chrome's own render.\n"
     "    if (window.LuxChrome) window.LuxChrome.frame(s, LUX_CTX, jumped);\n"),
    ("  var PB_MODE = false;\n  var PB_CTX = null;             // filled at the end of this IIFE (hoisted)\n",
     "  var LUX_CTX = null;            // filled at the end of this IIFE (hoisted)\n"),
    ("    if (!PB_MODE && s.regime !== undefined) PB_MODE = true;\n", ""),
    ("  PB_CTX = {", "  LUX_CTX = {"),
    ("  if (window.PaintballChrome) window.PaintballChrome.install(PB_CTX);",
     "  if (window.LuxChrome) window.LuxChrome.install(LUX_CTX);"),
    ("    teamName: teamName, rosterName: rosterName, shortName: shortName,\n"
     "    pushFeed: pushFeed, banner: banner, togglePov: togglePov,\n",
     "    teamName: teamName, rosterName: rosterName,\n"
     "    pushFeed: pushFeed, banner: banner, clearFeed: clearFeed,\n"
     "    seekToFraction: seekToFraction, setVerdict: setVerdict,\n"),
    # `syncViewUi` lived in the deleted #viewpanel region; the board is a
    # fixed grid that always fits, so a fit on the first frame is the whole
    # view contract.
    ("    onFirstFrame: function () { core.setViewportFit(); syncViewUi(); },",
     "    onFirstFrame: function () { core.setViewportFit(); },"),
    ("/* Opt-OUT of the #viewpanel overlay (zoom bar + minimap) by param only:\n"
     "   ?viewpanel=0 sets body[data-noviewpanel]. Defaults are unchanged everywhere\n"
     "   — the League Replayer shell loads the board with ?embed=1 and KEEPS zoom +\n"
     "   minimap (that's why #271 blanket-hiding the panel in all embeds was reverted\n"
     "   in #272). Only surfaces that explicitly ask — billboards (Lobby hero) and\n"
     "   thumbnail capture — append &viewpanel=0 to drop the panel. Independent of\n"
     "   embed: the two params don't touch each other. */\n",
     ""),
    ("    <!-- View controls: zoom the board with buttons/slider/keys/pinch (never a\n"
     "         plain scroll — that belongs to the page), and once zoomed, a minimap\n"
     "         with a white view box says which part of the board you are holding.\n"
     "         Click or drag the minimap to jump the view there. -->\n",
     ""),
    ("  // pov clear (togglePov lives in the shared chrome, driven via ctx.sendPov)\n"
     "  $('povBadge').addEventListener('click', function () { send('v:-1'); });\n",
     ""),
    ("  // ?viewpanel=0 hides the #viewpanel overlay (zoom bar + minimap). This is an\n"
     "  // explicit opt-OUT only — the default (param absent) is unchanged for every\n"
     "  // existing embed, so the League Replayer still shows zoom + minimap. See the\n"
     "  // #271/#272 lesson: hiding the panel for ALL embeds broke the Replayer shell.\n"
     "  // Billboards (Lobby hero) and thumbnail capture append &viewpanel=0.\n"
     "  try {\n"
     "    if (new URLSearchParams(location.search).get('viewpanel') === '0')\n"
     "      document.body.setAttribute('data-noviewpanel', '1');\n"
     "  } catch (e) {}\n\n",
     ""),
    ("    onTransform: function (t) { syncViewUi(t); }",
     "    onTransform: function (t) { void t; }"),
    # the view keys belonged to the dropped #viewpanel: a fixed 16x16 board
    # has no off-frame area to pan to.
    ("    // Board zoom rides z/x/0: +/- and 1..9 are already the server's speed\n"
     "    // commands, so they can't double as view keys.\n"
     "    else if (k === 'z') core.zoomAt(ZOOM_STEP);\n"
     "    else if (k === 'x') core.zoomAt(1 / ZOOM_STEP);\n"
     "    else if (k === '0') core.resetView();\n",
     ""),
    ("    // Arrows walk the view one CELL at a time; with shift, ten cells. A cell is\n"
     "    // a fixed distance in the WORLD — the same ground on every map and at every\n"
     "    // zoom — so arrowing is a way of stepping across the arena, not a nudge\n"
     "    // whose size depends on how far in you happen to be.\n"
     "    else if (k === 'ArrowLeft' || k === 'ArrowRight' ||\n"
     "             k === 'ArrowUp' || k === 'ArrowDown') {\n"
     "      var vt = core.getTransform();\n"
     "      if (!vt || !(vt.zoom > 1)) return;   // fitted whole: nowhere to go\n"
     "      ev.preventDefault();\n"
     "      var step = panCellBoardPx() * (ev.shiftKey ? 10 : 1);\n"
     "      var stepX = (k === 'ArrowLeft' ? -1 : k === 'ArrowRight' ? 1 : 0);\n"
     "      var stepY = (k === 'ArrowUp' ? -1 : k === 'ArrowDown' ? 1 : 0);\n"
     "      core.panByMap(stepX * step, stepY * step);\n"
     "    }\n",
     ""),
]

SPLICE_BANNER = "     PAINTBALL additions to the inherited coworld-ctf chrome"


def strip_css(text: str) -> str:
    out = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        hit = any(stripped.startswith(p) for p in DELETE_CSS_PREFIXES)
        if hit and ("{" in line or (i + 1 < len(lines) and "{" in lines[i + 1])):
            depth = 0
            started = False
            while i < len(lines):
                depth += lines[i].count("{") - lines[i].count("}")
                started = started or "{" in lines[i]
                i += 1
                if started and depth <= 0:
                    break
            continue
        out.append(line)
        i += 1
    return "\n".join(out)


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    starter_root, out_path = sys.argv[1], sys.argv[2]
    src = os.path.join(starter_root, "client", "replay_broadcast.html")
    lines = open(src, encoding="utf-8").read().split("\n")

    splice = next(i for i, l in enumerate(lines) if SPLICE_BANNER in l)
    # everything before the appended PAINTBALL block, back to its opening
    # comment fence
    end = splice
    while not lines[end].startswith("<!-- ====="):
        end -= 1
    head = lines[:end]

    drop = set()
    for first, last, _why in DELETE_REGIONS:
        for n in range(first - 1, last):
            drop.add(n)
    head = [l for i, l in enumerate(head) if i not in drop]
    text = "\n".join(head)

    for opener, closer in DELETE_MARKUP:
        start = text.index(opener)
        stop = text.index(closer, start) + len(closer)
        text = text[:start] + text[stop:]

    text = strip_css(text)

    for old, new in RELABEL + PATCH:
        if old not in text:
            raise SystemExit("fork_broadcast_page: anchor not found:\n" + old[:120])
        text = text.replace(old, new)

    block = open(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "lux_block.html"),
        encoding="utf-8",
    ).read()
    text = text.rstrip("\n") + "\n" + block
    open(out_path, "w", encoding="utf-8").write(text)
    print("wrote", out_path, len(text), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
