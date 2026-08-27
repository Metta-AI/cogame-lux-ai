## The observation contract, and the complete list of what is hidden.

import std/[json, strutils, unicode, unittest]

import lux/sim
import helpers

proc observationFor(game: SimServer, seat: int): JsonNode =
  game.seatObservation(seat, [10'i64, 4, 0], 2, 1, 0, 0, 1,
    "5 workers mined 410 wood")

suite "lux observation":
  test "the three ASCII layers are mapSize lines of mapSize legal characters":
    for mapSize in [12, 16]:
      var config = fixtureConfig(mapSize = mapSize)
      var game = initSimServer(config)
      for _ in 0 ..< 80:
        game.step()
      let view = game.observationFor(0)
      for (layer, legal) in [("terrain", ".wcu"), ("cities", ".RB"),
                             ("units", ".rRbB*")]:
        let rows = view["map"][layer]
        check rows.len == mapSize
        for row in rows:
          let text = row.getStr()
          check text.runeLen == mapSize
          for ch in text:
            check ch in legal

  test "a seat's view of the opponent's public state is byte-identical to the opponent's own":
    var game = scriptedEpisode(fixtureConfig(seed = 1734029581))
    let
      red = game.observationFor(0)
      blue = game.observationFor(1)
    ## Full observability, asserted from BOTH sides.
    check $red["map"] == $blue["map"]
    for kind in ["wood", "coal", "uranium"]:
      ## the totals are shared; `yours`/`theirs` are the same two numbers, swapped
      check red["resources"][kind]["tiles_left"] ==
        blue["resources"][kind]["tiles_left"]
      check red["resources"][kind]["amount_left"] ==
        blue["resources"][kind]["amount_left"]
      check red["resources"][kind]["yours"] == blue["resources"][kind]["theirs"]
      check red["resources"][kind]["theirs"] == blue["resources"][kind]["yours"]
    check $red["resources"]["richest"] == $blue["resources"]["richest"]
    ## `theirs` carries exactly the PUBLIC half of the opponent's own `yours`.
    for key in ["research", "city_tiles", "cities", "workers", "carts"]:
      check red["theirs"][key] == blue["yours"][key]
      check blue["theirs"][key] == red["yours"][key]
    check $red["theirs"]["city_list"] == $blue["yours"]["city_list"]
    check $blue["theirs"]["city_list"] == $red["yours"]["city_list"]

  test "city_list is capped at 8 with cities_omitted, cells at 12, richest at 6":
    var world = buildWorld()
    world.clearBoard()
    var cell = 0
    for i in 0 ..< 11:
      cell = i * 20 + 3
      discard world.cities.addTile(world.board, Red, cell)
      world.board.road[cell] = world.config.maxRoad
    ## one big city with more than twelve cells
    for i in 0 ..< 15:
      let big = 8 * world.board.size + i
      if not world.cities.hasTile(big):
        discard world.cities.addTile(world.board, Blue, big)
        world.board.road[big] = world.config.maxRoad
    for i in 0 ..< 9:
      world.board.terrain[200 + i] = tWood
      world.board.amount[200 + i] = 100 + i
    var game = initSimServer(fixtureConfig())
    game.world = world
    let red = game.observationFor(0)
    check red["yours"]["city_list"].len == MaxObservedCities
    check red["yours"]["cities_omitted"].getInt() == 11 - MaxObservedCities
    check red["resources"]["richest"].len <= MaxRichestTiles
    let blue = game.observationFor(1)
    check blue["yours"]["city_list"][0]["cells"].len == MaxObservedCells
    check blue["yours"]["city_list"][0]["cells_omitted"].getInt() > 0

  test "how_it_went is capped at 240 runes and is engine-written":
    var game = initSimServer(fixtureConfig())
    var long = ""
    for _ in 0 ..< 400:
      long.add("\u{1F600}")
    let view = game.seatObservation(0, [0'i64, 0, 0], 0, 0, 0, 0, 0, long)
    check view["how_it_went"].getStr().runeLen == MaxHowItWentRunes
    check view["how_it_went"].getStr().validateUtf8() == -1

  test "the seed, the opponent's directive and the opponent's note are nowhere in a seat's bytes":
    var game = scriptedEpisode(fixtureConfig(seed = 1734029581))
    game.directive[1].note = "SENTINEL-OPPONENT-NOTE"
    game.directive[1].stance = stTurtle
    game.seats[0].name = "daveey"
    game.seats[1].name = "daveey-1"
    for seat in 0 .. 1:
      let bytes = $game.observationFor(seat)
      check "SENTINEL-OPPONENT-NOTE" notin bytes
      check $game.config.seed notin bytes
      check "daveey" notin bytes
      ## the seat's OWN last directive is legitimately there
      check bytes.contains("your_last_directive")
    ## the opponent's stance is not exposed either
    check "turtle" notin $game.observationFor(0)

  test "the observation names only the two anonymous aliases":
    var game = scriptedEpisode(fixtureConfig(seed = 42))
    let view = $game.observationFor(0)
    check "RED-alpha" in view
    check "BLUE-alpha" in view
    check "lux-ai-forester" notin view
    check "lux-ai-prospector" notin view

  test "the observation is bounded no matter how many units are alive":
    var world = buildWorld()
    world.clearBoard()
    world.addCity(Red, 40, fuel = 500)
    for i in 0 ..< 60:
      discard world.units.spawn(Red, ukWorker, 40)
    var game = initSimServer(fixtureConfig())
    game.world = world
    check ($game.observationFor(0)).len < 8000
