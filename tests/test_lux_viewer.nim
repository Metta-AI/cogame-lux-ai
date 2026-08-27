## The chrome is the STARTER'S, not a lookalike — and the four 360 px rules.

import std/[algorithm, sequtils, strutils, unittest]

import lux/[sim, wire_constants]
import helpers

const
  # Pinned against coworld-ctf's files. A single edited byte fails here, which
  # is the whole point: everything lux-ai adds lives in the appended game block.
  ChromeCommonSha256 =
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
  BroadcastCoreSha256 =
    "172c4680129d608fd687cfd86436b675eef32c8652be6afe5f3189dd20c5aa9c"
  SpliceBanner = "LUX-AI additions to the inherited coworld-ctf chrome"

proc sha256Hex(data: string): string =
  ## Nim's stdlib ships SHA-1 only, so the pin is computed with the same
  ## FNV-free construction the test declares: a plain SHA-256 in Nim.
  ## (`std/sha1` is not enough for a content pin, so this is the real thing.)
  var h: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  const k: array[64, uint32] = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
    0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
    0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
    0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
    0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
    0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
    0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
    0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
    0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
    0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
    0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
    0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
    0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]
  proc rotr(x: uint32, n: int): uint32 = (x shr n) or (x shl (32 - n))
  var message = data
  let bitLength = uint64(data.len) * 8
  message.add('\x80')
  while message.len mod 64 != 56:
    message.add('\0')
  for shift in countdown(56, 0, 8):
    message.add(char((bitLength shr shift) and 0xff))
  var w: array[64, uint32]
  for block0 in countup(0, message.len - 1, 64):
    for i in 0 ..< 16:
      w[i] = (uint32(uint8(message[block0 + i * 4])) shl 24) or
        (uint32(uint8(message[block0 + i * 4 + 1])) shl 16) or
        (uint32(uint8(message[block0 + i * 4 + 2])) shl 8) or
        uint32(uint8(message[block0 + i * 4 + 3]))
    for i in 16 ..< 64:
      let
        s0 = rotr(w[i - 15], 7) xor rotr(w[i - 15], 18) xor (w[i - 15] shr 3)
        s1 = rotr(w[i - 2], 17) xor rotr(w[i - 2], 19) xor (w[i - 2] shr 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var v = h
    for i in 0 ..< 64:
      let
        s1 = rotr(v[4], 6) xor rotr(v[4], 11) xor rotr(v[4], 25)
        ch = (v[4] and v[5]) xor ((not v[4]) and v[6])
        temp1 = v[7] + s1 + ch + k[i] + w[i]
        s0 = rotr(v[0], 2) xor rotr(v[0], 13) xor rotr(v[0], 22)
        maj = (v[0] and v[1]) xor (v[0] and v[2]) xor (v[1] and v[2])
        temp2 = s0 + maj
      v[7] = v[6]; v[6] = v[5]; v[5] = v[4]; v[4] = v[3] + temp1
      v[3] = v[2]; v[2] = v[1]; v[1] = v[0]; v[0] = temp1 + temp2
    for i in 0 .. 7:
      h[i] = h[i] + v[i]
  for value in h:
    result.add(toHex(value, 8).toLowerAscii())

let
  page = readRepoFile("client/replay_broadcast.html")
  spliceAt = page.find(SpliceBanner)
  inherited = page[0 ..< spliceAt]
  gameBlock = page[spliceAt .. ^1]

suite "lux viewer":
  test "chrome_common.js is byte-identical to coworld-ctf's":
    check sha256Hex(readRepoFile("client/chrome_common.js")) ==
      ChromeCommonSha256
    ## and carries no lux edit at all
    let chrome = readRepoFile("client/chrome_common.js")
    check "lux" notin chrome.toLowerAscii().replace("include", "")
    check "window.ChromeCommon" in chrome
    for name in ["markBeat", "renderBeatMarkers", "ingestBeats", "renderClock",
                 "renderTransport", "ingestLullSpans", "setVerdict"]:
      check ("function " & name) in chrome

  test "broadcast_core.js is byte-identical to coworld-ctf's":
    ## Paintbot's draw layer turned out to be entirely game-AGNOSTIC — it is a
    ## sprite-protocol parser and compositor with no flags, paint, hills,
    ## grenades or hearts in it — so it is inherited whole rather than forked.
    ## Nothing to delete, nothing to add: this game's board is drawn from
    ## sprites the SAME Nim sim emits, exactly as the starter's is.
    let core = readRepoFile("client/broadcast_core.js")
    check sha256Hex(core) == BroadcastCoreSha256
    ## Game-agnostic in substance: not one ctf draw call in it. ("flags" and
    ## "paint" DO appear — they are the sprite-protocol layer flag field and
    ## the compositor's own repaint bookkeeping, which is exactly the point.)
    for name in ["renderFlag", "drawHeart", "hillOwner", "paintTiles",
                 "renderSquad", "drawFpv", "spraycan"]:
      checkpoint(name)
      check name notin core
    check "function pushFeed" notin core           ## pushFeed lives in the page

  test "the page is the starter's, with ONE appended game block":
    check spliceAt > 90_000                        ## the inherited chrome is most of it
    check page.startsWith("<!doctype html>") or page.startsWith("<!DOCTYPE html>")
    check page.count(SpliceBanner) == 1
    check "PAINTBALL additions" notin page
    check "window.PaintballChrome" notin page
    check "window.LuxChrome" in gameBlock
    ## the inherited region still carries the starter's landmarks
    for id in ["viewport", "stage", "board", "lightpool", "grain", "lockerroom",
               "chrome", "scorebug", "plates-l", "plates-r", "clock",
               "clock-time", "clock-caption", "bannerlane", "killfeed",
               "mmwarn", "transport", "btn-restart", "btn-back", "btn-play",
               "btn-fwd", "btn-end", "btn-loop", "btn-skip", "btn-spoilers",
               "ffwd-chip", "ffwd-mini", "win-chip", "tick-clock",
               "speedchips", "scrub", "momentum", "scrub-fill", "lulls",
               "scrub-win", "scrub-head", "endcard", "ec-headline",
               "ec-wincond", "ec-how", "ec-teams", "ec-replay", "status"]:
      checkpoint(id)
      check ("id=\"" & id & "\"") in inherited

  test "the dropped elements appear nowhere":
    for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-in",
               "zoom-out", "zoom-slider", "zoom-read", "fpv", "fpv-canvas",
               "fpv-hud", "fpv-name", "fpv-hp", "fpv-gear", "fpv-map",
               "fpv-map-canvas", "fpv-cap", "fpv-grip", "povBadge"]:
      checkpoint(id)
      check ("id=\"" & id & "\"") notin page
      check ("getElementById('" & id & "')") notin page
      check ("$('" & id & "')") notin page
    for selector in [".hillchip", ".hcap", ".flagicon", ".lives-num",
                     ".lives-label", ".squad-pip", ".pb-tags", "#pb-regime",
                     ".ec-heart", "attachMinimap"]:
      checkpoint(selector)
      check selector notin page

  test "the beat-marker CSS kinds are EXACTLY the four the sim emits":
    var kinds: seq[string]
    var at = 0
    while true:
      let found = page.find(".beat-marker.", at)
      if found < 0:
        break
      var stop = found + 13
      while stop < page.len and page[stop] in {'a' .. 'z'}:
        inc stop
      let kind = page[found + 13 ..< stop]
      if kind.len > 0 and kind notin kinds:
        kinds.add(kind)
      at = stop
    kinds.sort()
    check kinds == @["citylost", "dusk", "end", "research"]

  test "the transport rules the pin names":
    check "#endcard {" in page
    check "bottom: var(--band" in page
    ## relayout() sets all three custom properties on :root
    let relayoutAt = page.rfind("function relayout()")
    check relayoutAt > 0
    let relayout = page[relayoutAt ..< min(page.len, relayoutAt + 3000)]
    check "setProperty('--hudscale'" in relayout
    check "setProperty('--topband'" in relayout
    check "setProperty('--band'" in relayout
    ## every seek dismisses the endcard
    check "$('endcard').classList.remove('on')" in page
    ## the beats are labelled clickable BUTTONS that seek, not divs
    check "function luxBeat(" in gameBlock
    check "createElement('button')" in gameBlock
    check "setAttribute('aria-label'" in gameBlock
    check "CTX.send('s:' + tick)" in gameBlock
    ## and the game block NEVER calls the chrome's own div-marker builder
    check "markBeat(" notin gameBlock

  test "no game-block identifier collides with the chrome alias list":
    ## The cogame-tandem hoisting trap: the alias block declares its names with
    ## a hoisted `var`, so a game-block function of the same name is swallowed.
    var aliases: seq[string]
    for line in inherited.splitLines():
      let stripped = line.strip()
      if not stripped.startsWith("var ") or " = C." notin stripped:
        continue
      for part in stripped[4 .. ^1].split(','):
        let name = part.strip().split(" = ")[0].strip()
        if name.len > 0 and name notin aliases:
          aliases.add(name)
    check aliases.len > 15
    check "markBeat" in aliases
    for name in aliases:
      checkpoint("alias " & name)
      check ("function " & name & "(") notin gameBlock
      check ("var " & name & " =") notin gameBlock

  test "no overlay the game block adds sits inside the transport band":
    ## Everything positioned by the game block is anchored to the TOP band or
    ## inside the board region; nothing is anchored to the bottom.
    for rule in ["#cyclebar", "#researchrail", "#fuelstrip"]:
      let at = gameBlock.find(rule & " {")
      check at >= 0
      let body = gameBlock[at .. gameBlock.find("}", at)]
      checkpoint(rule & body)
      check "bottom:" notin body
    check "top: calc(var(--topband)" in gameBlock

  test "the four 360 px rules":
    check ".plate-name {" in gameBlock
    let plate = gameBlock[gameBlock.find(".plate-name {") ..
      gameBlock.find("}", gameBlock.find(".plate-name {"))]
    check "flex: 1 1 auto" in plate
    check "min-width: 3.2em" in plate
    check "text-overflow: ellipsis" in plate
    check "@media (max-width: 640px)" in gameBlock       ## labels hidden under 640
    check "#stage.tiny .plate .lux-sub" in gameBlock     ## 2: stats move to the clock
    check "#stage.tiny #fuelstrip .fs .lbl" in gameBlock ## 3: one bar per side
    check "#stage.tiny #researchrail .rr" in gameBlock
    check "#stage.tiny #cyclebar .cyc .num" in gameBlock ## 4: numerals dropped

  test "the commander band is sized from the server's own note cap":
    ## Checklist item 15: text laid out relative to another element gets a
    ## RESERVED band sized from the cap the server enforces on that string.
    ## The `note` is the only model-authored string this viewer draws; the
    ## inherited `.feed-row` is a nowrap row sized for a 10-char NAME, so the
    ## commander line gets its own wrapping band and the band declares the cap
    ## it was sized from. Move MaxNoteRunes without resizing the band and this
    ## fails.
    check ("--lux-note-runes: " & $MaxNoteRunes & ";") in gameBlock
    check ".feed-row.lux-say {" in gameBlock
    let bandAt = gameBlock.find(".feed-row.lux-say {")
    let band = gameBlock[bandAt .. gameBlock.find("}", bandAt)]
    checkpoint(band)
    check "white-space: normal" in band
    check "min-height: var(--lux-say-band)" in band
    check "width: 100%" in band
    ## the wrap survives a 160-rune note with no spaces in it
    check "overflow-wrap: anywhere" in gameBlock
    ## and it is the DIRECTIVE rows that carry the band
    check "'lux-say'" in gameBlock
    ## `.tiny` needs five lines for the same cap, and must RE-DECLARE the band
    ## to get them: a custom property is substituted at the computed-value time
    ## of the element it is declared on, so inheriting `:root`'s already
    ## resolved value keeps the four-line reserve however many lines
    ## `--lux-note-lines` is overridden to.
    let tinyAt = gameBlock.find("#stage.tiny {")
    check tinyAt >= 0
    let tiny = gameBlock[tinyAt .. gameBlock.find("}", tinyAt)]
    checkpoint(tiny)
    check "--lux-note-lines: 5" in tiny
    check "--lux-say-band:" in tiny

  test "the worst-case fixture feeds a FULL-CAP note and reads it back":
    ## The fixture asserts its own strings are still full length — a quietly
    ## shortened remark leaves it passing while testing nothing — and it does
    ## the measuring this game needs, because every string it draws is DOM and
    ## the harness's canvas tally is structurally 0 here.
    let fixture = readRepoFile("tools/ci/renderer_fixture.html")
    check ("var NOTE_RUNES = " & $MaxNoteRunes & ";") in fixture
    check "runeCap(NOTE_A, NOTE_RUNES)" in fixture
    check "entry.runes !== NOTE_RUNES" in fixture
    check "getBoundingClientRect" in fixture
    check "LUX-TEXTFIT " in fixture
    check "data-replay-error" in fixture
    ## and ci.yml gates on the measurement rather than merely printing it
    let workflow = readRepoFile(".github/workflows/ci.yml")
    check "The commander line fits its band" in workflow
    check "LUX-TEXTFIT " in workflow

  test "no ctf_/CTF_/PB_ identifier survives outside the documented alias":
    for path in ["client/replay_broadcast.html", "client/broadcast_core.js",
                 "replay-viewer/static_replay.js",
                 "replay-viewer/static_replay_worker.js",
                 "replay-viewer/config.nims", "replay-viewer/lux_replay.nim",
                 "src/lux/wire_constants.nim"]:
      let source = readRepoFile(path)
      var allowed = 0
      if path == "client/broadcast_core.js":
        allowed = source.count("CTF_WIRE")      ## inherited byte-for-byte
      elif path == "src/lux/wire_constants.nim":
        allowed = source.count("CTF_WIRE")      ## the documented alias emitter
      checkpoint(path)
      check source.count("CTF_") == allowed
      check source.count("ctf_") == 0
      check source.count("PB_") == 0
      check source.count("Ctf") == 0

  test "wire_constants publishes LUX_WIRE and aliases CTF_WIRE exactly once":
    check WireConstantsJs.startsWith("window.LUX_WIRE={")
    check WireConstantsJs.count("window.CTF_WIRE=window.LUX_WIRE;") == 1
    check ("chromeSpriteId:" & $BroadcastChromeSpriteId) in WireConstantsJs
    check ("fps:" & $ReplayFps) in WireConstantsJs

  test "the static shell sets the load and error signals on <html>":
    let shell = readRepoFile("replay-viewer/static_replay.js")
    check "setAttribute('data-replay-loaded', 'true')" in shell
    check "'data-replay-error'" in shell
    ## and the loaded attribute is set in the 'loaded' branch, i.e. AFTER the
    ## Worker has handed BroadcastCore the first frame
    let loadedAt = shell.find("message.type === 'loaded'")
    check loadedAt > 0
    check shell.find("data-replay-loaded", loadedAt) > loadedAt

  test "the emscripten link flags and the JS bootstrap are the matched pair":
    let flags = readRepoFile("replay-viewer/config.nims")
    let worker = readRepoFile("replay-viewer/static_replay_worker.js")
    ## paintbot lineage: NON-modularized, the Worker waits for
    ## Module.onRuntimeInitialized. A MODULARIZE/EXPORT_NAME mixture with this
    ## bootstrap hangs on "Loading replay..." forever (cogame-lantern).
    check "MODULARIZE" notin flags
    check "EXPORT_NAME" notin flags
    check "Module.onRuntimeInitialized" in worker
    check "-s ABORTING_MALLOC=1" in flags
    check "-s ALLOW_MEMORY_GROWTH" in flags
    check "-s FILESYSTEM=1" in flags
    check "-s ENVIRONMENT=web,worker,node" in flags
    check "--preload-file" in flags
    for exported in ["_lux_load_replay", "_lux_frame", "_lux_input",
                     "_lux_packet_ptr", "_lux_packet_len", "_lux_mismatch_tick",
                     "_lux_error_ptr", "_lux_error_len", "_lux_stage_ptr",
                     "_lux_stage_len"]:
      check exported in flags
    check "importScripts('./wire_constants.js', './broadcast_core.js', " &
      "'./lux_replay.js')" in worker

  test "the replay-viewer build hook is committed executable and points at this repo":
    let hook = readRepoFile("tools/build_replay_viewer.sh")
    check "coworld-lux-ai-replay-viewer-build" in hook
    check "/workspace/lux/replay-viewer/dist/." in hook
    check "mkdir -p \"$(dirname \"${requested_output}\")\"" in hook
