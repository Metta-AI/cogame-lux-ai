## Tolerant parsing, repair, and the RUNE-boundary discipline.

import std/[json, strutils, unicode, unittest]

import lux/sim
import helpers

const Emoji = "\u{1F600}"   ## a 4-byte codepoint

proc parse(text: string, previous = defaultDirective()): Directive =
  parseDirective(extractJsonObject(text), previous, 16)

suite "lux directives":
  test "prose-prefixed and fenced JSON both parse":
    check parse("Sure! Here you go:\n{\"stance\":\"fuel\"}").stance == stFuel
    check parse("```json\n{\"stance\":\"turtle\"}\n```").stance == stTurtle
    check parse("{\"stance\":\"contest\"} — hope that helps").stance == stContest

  test "numeric strings, hyphens and case are all accepted":
    let directive = parse("""{"stance":"  ExPaNd ","workers":"12","carts":"3",
      "research":"URANIUM","night":"Shelter","build":"AUTO"}""")
    check directive.stance == stExpand
    check directive.workers == 12
    check directive.carts == 3
    check directive.research == rtUranium
    check directive.night == npShelter
    check directive.build == boAuto

  test "an unknown stance keeps last turn's; unknown enums take their defaults":
    var previous = defaultDirective()
    previous.stance = stTurtle
    check parse("""{"stance":"rampage"}""", previous).stance == stTurtle
    check parse("""{"research":"plutonium"}""").research == rtCoal
    check parse("""{"build":"spaceship"}""").build == boAuto
    check parse("""{"night":"party"}""").night == npShelter

  test "mine: duplicates dropped, missing kinds appended, empty repaired":
    check parse("""{"mine":["coal","coal","wood"]}""").mine ==
      [tCoal, tWood, tUranium]
    check parse("""{"mine":["uranium"]}""").mine == [tUranium, tWood, tCoal]
    check parse("""{"mine":[]}""").mine == [tWood, tCoal, tUranium]
    check parse("""{"mine":"wood"}""").mine == [tWood, tCoal, tUranium]

  test "workers and carts clamp, and repairs are counted":
    let high = parse("""{"workers":999,"carts":-3}""")
    check high.workers == MaxWorkers
    check high.carts == 0
    check high.repaired == 2

  test "focus: off the board clamps, an {x,y} object is accepted, null clears":
    let clamped = parse("""{"focus":[99,-4]}""")
    check clamped.hasFocus
    check clamped.focusX == 15
    check clamped.focusY == 0
    let objectForm = parse("""{"focus":{"x":3,"y":11}}""")
    check objectForm.hasFocus
    check objectForm.focusX == 3
    check objectForm.focusY == 11
    check not parse("""{"focus":null}""").hasFocus
    check not parse("""{"focus":"middle"}""").hasFocus

  test "a 300-character note is truncated to 160 RUNES":
    var long = ""
    for _ in 0 ..< 300:
      long.add('x')
    let directive = parse("""{"note":"""" & long & """"}""")
    check directive.note.runeLen == MaxNoteRunes

  test "a reply with ONLY a note is usable and keeps the current directive":
    var previous = defaultDirective()
    previous.stance = stTurtle
    previous.workers = 11
    let directive = parse("""{"note":"holding the blob"}""", previous)
    check directive.stance == stTurtle
    check directive.workers == 11
    check directive.note == "holding the blob"

  test "a non-object reply is a parse failure":
    expect DirectiveError:
      discard parse("no json at all, sorry")
    expect DirectiveError:
      discard parse("")

  test "a 9 KB reply is capped, and the cut-open remainder fails as a CLASSIFIED error":
    var padding = ""
    for _ in 0 ..< 9000:
      padding.add('y')
    let capped = ("""{"stance":"fuel","note":"""" & padding & """"}""")
      .truncateRunes(MaxReplyBytes)
    check capped.runeLen == MaxReplyBytes
    ## The cap cuts the JSON open — this reply keeps its opening brace and
    ## loses its closing one entirely, so there is nothing for the tolerant
    ## extractor's first-brace..last-brace rescue to grab. What matters is
    ## that the caller sees a DirectiveError it can record as `parse_error`,
    ## never an unclassified JsonParsingError from underneath.
    var reason = "parsed"
    try:
      discard parse(capped)
    except DirectiveError as error:
      reason = error.msg
    check reason.startsWith("no JSON object in reply")
    ## and a 9 KB reply whose object CLOSES inside the cap parses normally
    let survivor = ("""{"stance":"fuel","note":"n"} """ & padding)
      .truncateRunes(MaxReplyBytes)
    check parse(survivor).stance == stFuel

  test "a note whose 160th and 161st characters are a 4-byte emoji cuts on the RUNE":
    var note = ""
    for _ in 0 ..< 159:
      note.add('a')
    note.add(Emoji)
    note.add(Emoji)
    check note.runeLen == 161
    let cut = sanitizeNote(note)
    check cut.runeLen == MaxNoteRunes
    check cut.validateUtf8() == -1              ## still strict UTF-8
    check cut.endsWith(Emoji)
    ## and it round-trips through %$ -> parseJson and back
    let round = parseJson($(%*{"note": cut}))
    check round["note"].getStr() == cut
    check round["note"].getStr().validateUtf8() == -1

  test "every capped string is cut on a rune boundary, not a byte":
    for cap in [MaxNoteRunes, MaxPolicyLabelRunes, MaxFallbackDetailRunes,
                MaxPromptRunes, MaxHowItWentRunes]:
      var text = ""
      for _ in 0 ..< cap + 40:
        text.add(Emoji)
      let cut = text.truncateRunes(cap)
      check cut.runeLen == cap
      check cut.len == cap * 4                  ## whole 4-byte codepoints
      check cut.validateUtf8() == -1

  test "the directive record carries the note and the view and stays valid JSON":
    var directive = parse("""{"stance":"fuel","note":"coal belt"}""")
    directive.source = dsLlm
    directive.latencyMs = 3412
    let record = directive.directiveRecord(120, 0, "RED-alpha", %*{"turn": 120})
    check record["k"].getStr() == "directive"
    check record["note"].getStr() == "coal belt"
    check record["source"].getStr() == "llm"
    check record["latency_ms"].getInt() == 3412
    check record["view"]["turn"].getInt() == 120
    check ($record).validateUtf8() == -1
