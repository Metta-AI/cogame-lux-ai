## Determinism: no floating point in the sim, the same seed reproduces
## byte-identically, and city fuel stays inside int64.

import std/[os, strutils, unittest]

import lux/sim
import helpers

const IntegerOnly = [
  "sim.nim", "board.nim", "units.nim", "cities.nim", "resolve.nim",
  "micro.nim", "baselines.nim"]
  ## `scoring.nim` is checked separately: it owns the ONE documented float in
  ## the whole sim, `scoreOf`, which turns the integer {0, 1, 2} match point
  ## into the 0.0 / 0.5 / 1.0 the league eats — at SERIALISATION time, never
  ## inside the sim.

suite "lux determinism":
  test "no floating point in the integer-only sim modules":
    for name in IntegerOnly:
      let source = readRepoFile("src/lux/" & name)
      var index = 0
      for line in source.splitLines():
        inc index
        let stripped = line.strip()
        if stripped.startsWith("#") or stripped.startsWith("##"):
          continue
        let code = block:
          let at = line.find("  ## ")
          if at >= 0: line[0 ..< at] else: line
        for banned in ["float", "sqrt(", "hypot(", "sin(", "cos("]:
          if banned in code:
            checkpoint(name & ":" & $index & " " & stripped)
            check banned notin code

  test "scoring.nim's only float is the documented serialisation boundary":
    var inScoreOf = false
    var offenders: seq[string] = @[]
    for line in readRepoFile("src/lux/scoring.nim").splitLines():
      let stripped = line.strip()
      if stripped.startsWith("func ") or stripped.startsWith("proc "):
        inScoreOf = stripped.startsWith("func scoreOf")
      if stripped.startsWith("#"):
        continue
      for banned in ["float", "sqrt(", "hypot(", "sin(", "cos("]:
        if banned in line and not inScoreOf:
          offenders.add(stripped)
    check offenders.len == 0

  test "two runs from the same seed produce identical state streams":
    var hashesA, hashesB: seq[uint64]
    for target in [addr hashesA, addr hashesB]:
      var game = initSimServer(fixtureConfig(seed = 1734029581))
      game.seats[0].joined = true
      game.seats[1].joined = true
      var lastDirective = -1
      while not game.episodeFinished():
        if game.phase == Playing and
            game.isDirectiveTurn(game.world.turn) and
            game.world.turn != lastDirective:
          lastDirective = game.world.turn
          game.setDirective(0, scriptedDirective(game.world, blForester, 0))
          game.setDirective(1, scriptedDirective(game.world, blProspector, 1))
        target[].add(game.gameHash())
        game.step()
    check hashesA.len > 300
    check hashesA == hashesB

  test "two different seeds do not":
    var a = scriptedEpisode(fixtureConfig(seed = 1734029581))
    var b = scriptedEpisode(fixtureConfig(seed = 424242))
    check a.gameHash() != b.gameHash()

  test "city fuel stays inside int64 under a uranium economy":
    var world = buildWorld()
    world.clearBoard()
    world.addCity(Red, 40, fuel = 0)
    for turn in 0 ..< 400:
      let carrier = world.addUnit(Red, ukCart, 40, uranium = CartCargo)
      world.turn = turn
      world.resolveTurn(TurnOrders(), turn)
      discard carrier
      check world.cities.list[0].fuel >= 0
      check world.cities.list[0].fuel < MaxCityFuel
    check world.cities.list[0].fuel > 1_000_000

  test "the hash mixes the structured directive but never the note":
    var world = buildWorld()
    let base = world.gameHash()
    world.directiveBytes[0][0] = 3'u8
    check world.gameHash() != base
    ## The note lives on `Directive`, which the world never stores, so there is
    ## nothing a commander SAYS that can move the chain — assert the shape.
    var directive = defaultDirective()
    directive.note = "a very long spectator-only line"
    check encodeDirective(directive).len == DirectiveBytes
    var quiet = defaultDirective()
    check encodeDirective(directive) == encodeDirective(quiet)
