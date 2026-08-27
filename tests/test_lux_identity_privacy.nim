## The TWO NAME SPACES pin, asserted from both sides.

import std/[json, strutils, unittest]

import lux/[broadcast, sim, llm]
import helpers

const Sentinel = "daveey-sentinel-policy"

suite "lux identity privacy":
  test "cogAlias is the starter's, untouched":
    check cogAlias(0) == "RED-alpha"
    check cogAlias(1) == "BLUE-alpha"
    check IdentityNames[0] == "alpha"
    check slotIdentityIndex(0) == 0
    check slotIdentityIndex(1) == 0
    check teamForSlot(0) == Red
    check teamForSlot(1) == Blue

  test "no seat-facing byte carries a real policy name":
    var game = scriptedEpisode(fixtureConfig(seed = 42))
    for seat in 0 .. 1:
      game.seats[seat].name = Sentinel & "-" & $seat
      game.seats[seat].policyLabel = Sentinel & "-label-" & $seat
    for seat in 0 .. 1:
      let view = $game.seatObservation(seat, [0'i64, 0, 0], 0, 0, 0, 0, 0, "")
      check Sentinel notin view
      ## the whole LLM message, system prompt and operator block included
      let message = userMessage("my own guidance", view)
      check Sentinel notin message
      check "RED-alpha" in SystemPrompt or "RED" in SystemPrompt

  test "the directive record's `view` never carries a policy address either":
    var game = scriptedEpisode(fixtureConfig(seed = 42))
    game.seats[0].name = Sentinel
    let view = game.seatObservation(0, [0'i64, 0, 0], 0, 0, 0, 0, 0, "")
    let record = game.directive[0].directiveRecord(10, 0, cogAlias(0), view)
    check Sentinel notin $record["view"]
    check record["alias"].getStr() == "RED-alpha"

  test "the broadcast stream, the roster and results.names MUST carry it":
    var game = scriptedEpisode(fixtureConfig(seed = 42))
    game.seats[0].name = Sentinel
    game.seats[1].name = Sentinel & "-1"
    let roster = $game.rosterJson()
    check Sentinel in roster
    check "RED-alpha" in roster            ## both name spaces, never either
    let results = parseJson(game.luxResultsJson())
    check results["names"][0].getStr() == Sentinel
    check results["aliases"][0].getStr() == "RED-alpha"
    var tracker = initBroadcastTracker()
    let state = game.buildStateJson(tracker, newJArray(), false, 1, 400,
      false, true, -1, 0, false, false)
    check Sentinel in state
    check "RED-alpha" in state

  test "showPlayerLabels is off by default":
    check not defaultGameConfig().showPlayerLabels
