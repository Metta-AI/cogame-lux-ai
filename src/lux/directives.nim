## The directive schema: what a commander (LLM or scripted) may say, how a
## reply is parsed TOLERANTLY, and how an illegal reply is REPAIRED rather than
## rejected. Forked from coworld-ctf's `src/ctf/directives.nim`.
##
## Both policy kinds emit the SAME object through the SAME validator, which is
## what makes the bounded-orders test in `tests/test_lux_baselines.nim`
## meaningful.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES and every truncation
## lands on a rune boundary (`runeLen` / `runeSubStr`). Slicing a string by
## BYTE index anywhere on the path to the replay is forbidden: a byte-truncated
## multi-byte character renders fine in a browser and then fails a strict UTF-8
## parser.

import std/[json, strutils, unicode]

import sim_types

type
  Stance* = enum
    stExpand = "expand"
    stFuel = "fuel"
    stResearch = "research"
    stContest = "contest"
    stTurtle = "turtle"

  ResearchTarget* = enum
    rtNone = "none"
    rtCoal = "coal"
    rtUranium = "uranium"
    rtAlways = "always"

  BuildOrder* = enum
    boAuto = "auto"
    boCity = "city"
    boWorker = "worker"
    boCart = "cart"

  NightPolicy* = enum
    npShelter = "shelter"
    npMine = "mine"
    npHaul = "haul"

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  Directive* = object
    ## One seat's whole strategy for the next `directiveEvery` turns.
    ## The first NINE fields are the structured directive: they are the 13
    ## bytes written as an input record and mixed into `gameHash`.
    stance*: Stance
    mine*: array[3, Terrain]
    research*: ResearchTarget
    build*: BuildOrder
    workers*: int
    carts*: int
    hasFocus*: bool
    focusX*, focusY*: int
    night*: NightPolicy
    # --- presentation only, NEVER hashed ---------------------------------
    note*: string
    source*: DirectiveSource
    latencyMs*: int
    repaired*: int          ## how many fields the validator had to repair.

  DirectiveError* = object of LuxError

const
  MaxWorkers* = 40
  MaxCarts* = 10
  DirectiveBytes* = 13

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single place
  ## any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeNote*(text: string): string =
  ## The commander's own line, as it reaches the replay and the match feed.
  ## Newlines collapse to spaces so one record stays one line, and the cut is
  ## the LAST thing that happens so it always lands on a rune boundary.
  text.replace("\n", " ").replace("\r", " ").replace("\t", " ")
    .strip().truncateRunes(MaxNoteRunes)

func defaultDirective*(): Directive =
  Directive(
    stance: stExpand,
    mine: [tWood, tCoal, tUranium],
    research: rtCoal,
    build: boAuto,
    workers: 6,
    carts: 1,
    hasFocus: false,
    night: npShelter,
    source: dsScripted
  )

proc encodeDirective*(directive: Directive): array[DirectiveBytes, uint8] =
  ## The 13 structured bytes. This is the game's ENTIRE input log: it is a
  ## load-bearing replay input record, re-applied before the turn is stepped,
  ## and it is what `gameHash` mixes.
  result[0] = uint8(ord(directive.stance))
  for i in 0 .. 2:
    result[1 + i] = uint8(ord(directive.mine[i]))
  result[4] = uint8(ord(directive.research))
  result[5] = uint8(ord(directive.build))
  result[6] = uint8(clamp(directive.workers, 0, MaxWorkers))
  result[7] = uint8(clamp(directive.carts, 0, MaxCarts))
  result[8] = if directive.hasFocus: 1'u8 else: 0'u8
  result[9] = uint8(clamp(directive.focusX, 0, 255))
  result[10] = uint8(clamp(directive.focusY, 0, 255))
  result[11] = uint8(ord(directive.night))
  result[12] = 0'u8            ## reserved; keeps the record a fixed 13 bytes.

proc decodeDirective*(bytes: openArray[uint8]): Directive =
  ## The inverse, used by the replay runtime before it steps the same turn.
  result = defaultDirective()
  if bytes.len < DirectiveBytes:
    return
  if int(bytes[0]) <= ord(high(Stance)):
    result.stance = Stance(int(bytes[0]))
  for i in 0 .. 2:
    let value = int(bytes[1 + i])
    if value >= ord(tWood) and value <= ord(tUranium):
      result.mine[i] = Terrain(value)
  if int(bytes[4]) <= ord(high(ResearchTarget)):
    result.research = ResearchTarget(int(bytes[4]))
  if int(bytes[5]) <= ord(high(BuildOrder)):
    result.build = BuildOrder(int(bytes[5]))
  result.workers = int(bytes[6])
  result.carts = int(bytes[7])
  result.hasFocus = bytes[8] != 0
  result.focusX = int(bytes[9])
  result.focusY = int(bytes[10])
  if int(bytes[11]) <= ord(high(NightPolicy)):
    result.night = NightPolicy(int(bytes[11]))

# ---------------------------------------------------------------------------
#  Tolerant parsing
# ---------------------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc normaliseEnum(text: string, limit: int): string =
  text.truncateRunes(limit).strip().toLowerAscii()
    .replace("-", "_").replace(" ", "_")

proc readInteger(node: JsonNode): tuple[ok: bool, value: int] =
  ## An int, a float, or a NUMERIC STRING. Anything non-finite or unparseable
  ## reports `ok = false` so the caller keeps last turn's value rather than
  ## inventing one.
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt:
    (true, int(node.getBiggestInt()))
  of JFloat:
    let value = node.getFloat()
    if value != value or value > 1.0e9 or value < -1.0e9: (false, 0)
    else: (true, int(value))
  of JString:
    try: (true, int(parseFloat(node.getStr().strip())))
    except CatchableError: (false, 0)
  else:
    (false, 0)

proc parseDirective*(
  payload: JsonNode, previous: Directive, mapSize: int
): Directive =
  ## Turns one parsed reply into a legal directive, REPAIRING every field the
  ## schema bounds. Unknown top-level keys are ignored, and a reply with a
  ## valid `note` and no usable field IS usable — the seat keeps its current
  ## directive and the note reaches the feed. Only when no JSON object at all
  ## can be recovered do the retry and then the scripted fallback fire.
  result = previous
  result.source = dsLlm
  result.repaired = 0
  result.latencyMs = 0
  result.note = sanitizeNote(payload{"note"}.getStr())

  block stance:
    let raw = payload{"stance"}
    if raw.isNil or raw.kind != JString:
      if not raw.isNil: inc result.repaired
      break stance
    let key = normaliseEnum(raw.getStr(), 10)
    for value in Stance:
      if $value == key:
        result.stance = value
        break stance
    inc result.repaired

  block mine:
    let raw = payload{"mine"}
    var picked: seq[Terrain] = @[]
    if not raw.isNil and raw.kind == JArray:
      var seen = 0
      for entry in raw:
        if seen >= 3:
          break
        inc seen
        if entry.kind != JString:
          inc result.repaired
          continue
        let key = normaliseEnum(entry.getStr(), 8)
        var matched = false
        for kind in [tWood, tCoal, tUranium]:
          if $kind == key and kind notin picked:
            picked.add(kind)
            matched = true
            break
        if not matched:
          inc result.repaired
    elif not raw.isNil:
      inc result.repaired
    if picked.len == 0:
      result.mine = [tWood, tCoal, tUranium]
    else:
      for kind in [tWood, tCoal, tUranium]:
        if kind notin picked:
          picked.add(kind)
      for i in 0 .. 2:
        result.mine[i] = picked[i]

  block research:
    let raw = payload{"research"}
    if raw.isNil or raw.kind != JString:
      if not raw.isNil: inc result.repaired
      break research
    let key = normaliseEnum(raw.getStr(), 8)
    for value in ResearchTarget:
      if $value == key:
        result.research = value
        break research
    result.research = rtCoal
    inc result.repaired

  block build:
    let raw = payload{"build"}
    if raw.isNil or raw.kind != JString:
      if not raw.isNil: inc result.repaired
      break build
    let key = normaliseEnum(raw.getStr(), 8)
    for value in BuildOrder:
      if $value == key:
        result.build = value
        break build
    result.build = boAuto
    inc result.repaired

  block workers:
    let read = readInteger(payload{"workers"})
    if not read.ok:
      if not payload{"workers"}.isNil: inc result.repaired
      break workers
    if read.value < 0 or read.value > MaxWorkers:
      inc result.repaired
    result.workers = clamp(read.value, 0, MaxWorkers)

  block carts:
    let read = readInteger(payload{"carts"})
    if not read.ok:
      if not payload{"carts"}.isNil: inc result.repaired
      break carts
    if read.value < 0 or read.value > MaxCarts:
      inc result.repaired
    result.carts = clamp(read.value, 0, MaxCarts)

  block night:
    let raw = payload{"night"}
    if raw.isNil or raw.kind != JString:
      if not raw.isNil: inc result.repaired
      break night
    let key = normaliseEnum(raw.getStr(), 8)
    for value in NightPolicy:
      if $value == key:
        result.night = value
        break night
    result.night = npShelter
    inc result.repaired

  block focus:
    let raw = payload{"focus"}
    if raw.isNil or raw.kind == JNull:
      result.hasFocus = false
      break focus
    var
      rx = (ok: false, value: 0)
      ry = (ok: false, value: 0)
    if raw.kind == JArray and raw.len >= 2:
      rx = readInteger(raw[0])
      ry = readInteger(raw[1])
    elif raw.kind == JObject:
      rx = readInteger(raw{"x"})
      ry = readInteger(raw{"y"})
    if not rx.ok or not ry.ok:
      result.hasFocus = false
      inc result.repaired
      break focus
    if rx.value < 0 or ry.value < 0 or rx.value >= mapSize or ry.value >= mapSize:
      inc result.repaired
    result.hasFocus = true
    result.focusX = clamp(rx.value, 0, mapSize - 1)
    result.focusY = clamp(ry.value, 0, mapSize - 1)

proc directiveJson*(directive: Directive): JsonNode =
  ## The nine structured fields, exactly as the reply schema declares them.
  var mine = newJArray()
  for kind in directive.mine:
    mine.add(%($kind))
  result = %*{
    "stance": $directive.stance,
    "mine": mine,
    "research": $directive.research,
    "build": $directive.build,
    "workers": directive.workers,
    "carts": directive.carts,
    "night": $directive.night
  }
  if directive.hasFocus:
    result["focus"] = %[directive.focusX, directive.focusY]
  else:
    result["focus"] = newJNull()

proc directiveRecord*(
  directive: Directive, turn, seat: int, alias: string, view: JsonNode
): JsonNode =
  ## The replay CHAT record for one turn's directive: presentation only,
  ## re-applied at playback into non-hashed fields. The structured bytes ride
  ## the input stream separately and are the only load-bearing half.
  result = directive.directiveJson()
  result["k"] = %"directive"
  result["turn"] = %turn
  result["seat"] = %seat
  result["alias"] = %alias
  result["source"] = %($directive.source)
  result["latency_ms"] = %directive.latencyMs
  result["note"] = %directive.note.truncateRunes(MaxNoteRunes)
  result["view"] = (if view.isNil: newJNull() else: view)
