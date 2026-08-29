## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with. Rendered ONCE from the same Nim consts the engine
## runs on; `server.nim` splices it into every served client page and
## `tools/gen_wire_constants.nim` emits it for the static wasm bundle.
##
## `client/chrome_common.js` is copied BYTE-FOR-BYTE from coworld-ctf and its
## line 72 reads `window.CTF_WIRE`; `client/broadcast_core.js` is copied
## byte-for-byte too and reads the same global at its line 49. Rather than edit
## two files the viewer test pins as byte-identical, the emitter publishes the
## game's own `window.LUX_WIRE` and ALIASES `window.CTF_WIRE` to it. Those are
## the only three places the `CTF_WIRE` name survives in this repo, each is
## inherited or documented here, and the CI rename grep excludes exactly them.

import std/strutils

import sim

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, value in values:
    if i > 0: result.add(",")
    result.add($value)
  result.add("]")

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeedIndex, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.LUX_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $ReplayFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",cell:" & $CellPixels &
  ",coalAt:" & $CoalResearch &
  ",uraniumAt:" & $UraniumResearch &
  "};window.CTF_WIRE=window.LUX_WIRE;"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker, "<script>" & WireConstantsJs & "</script>")
