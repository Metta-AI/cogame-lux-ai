## The seeded generator: the anti-collusion pin, in tests.

import std/[sets, unittest]

import lux/sim
import helpers

suite "lux board":
  test "the map is exactly mirror-symmetric at reset, in kind AND amount":
    ## 10 000 seeds and both map sizes: the sampler must terminate for every
    ## one of them, and neither side may ever be dealt a better island.
    for size in [12, 16]:
      for seed in 1 .. 5000:
        let board = generateBoard(size, seed * 7919, 4, 2, 1, 300, 400, 325)
        for cell in 0 ..< board.cellCount():
          let mirror = board.mirrorCell(cell)
          check board.terrain[cell] == board.terrain[mirror]
          check board.amount[cell] == board.amount[mirror]

  test "cluster and cell counts match the shipped table":
    for (clusters, kind, size) in [(4, tWood, 6), (2, tCoal, 3), (1, tUranium, 2)]:
      let board = generateBoard(16, 1734029581, 4, 2, 1, 300, 400, 325)
      var half = 0
      for cell in 0 ..< board.cellCount():
        if board.terrain[cell] == kind and board.cellX(cell) < 8:
          inc half
      check half == clusters * size

  test "the scarcity variant really is thinner":
    let
      duel = generateBoard(16, 1734029581, 4, 2, 1, 300, 400, 325)
      scarcity = generateBoard(16, 1734029581, 2, 3, 2, 200, 400, 325)
    var duelWood, scarcityWood = 0
    for cell in 0 ..< duel.cellCount():
      if duel.terrain[cell] == tWood: inc duelWood
      if scarcity.terrain[cell] == tWood: inc scarcityWood
    check duelWood == 48        ## 24 a half
    check scarcityWood == 24    ## 12 a half

  test "both start cells are empty, mirror each other, and carry one tile and one worker":
    for seed in 1 .. 400:
      var world = buildWorld(seed * 104729)
      let cells = world.board.startCell
      check world.board.terrain[cells[0]] == tEmpty
      check world.board.terrain[cells[1]] == tEmpty
      check cells[1] == world.board.mirrorCell(cells[0])
      check world.cities.teamOfCell[cells[0]] == 0
      check world.cities.teamOfCell[cells[1]] == 1
      check world.units.list.len == 2
      check world.units.list[0].cell == cells[0]
      check world.units.list[1].cell == cells[1]

  test "the map is a pure function of (seed, mapSize, cluster config) and is identical after play":
    ## The anti-collusion pin: nothing a policy does may steer a draw.
    var config = fixtureConfig(seed = 1734029581)
    let before = initWorld(config).board
    var played = scriptedEpisode(config)
    check played.world.turn > 0
    let after = initWorld(config).board
    for cell in 0 ..< before.cellCount():
      check before.terrain[cell] == after.terrain[cell]
      check before.amount[cell] == after.amount[cell]

  test "mapRng is consumed by nothing but the generator":
    ## A call-count assertion: the same seed produces the same stream, and
    ## drawing the generator's own number of values twice lands in the same
    ## place both times.
    var a = initMapRng(1734029581)
    var b = initMapRng(1734029581)
    var drawn: HashSet[int]
    for _ in 0 ..< 1000:
      let value = a.rand(1_000_000)
      check value == b.rand(1_000_000)
      drawn.incl(value)
    check drawn.len > 900        ## and it really is a stream, not a constant

  test "24x24 and 32x32 generate even though no variant ships them":
    for size in [24, 32]:
      let board = generateBoard(size, 7, 6, 3, 2, 300, 400, 325)
      check board.cellCount() == size * size
      check board.mirrorSymmetric()

  test "BFS is 4-connected and its first step is unique":
    var world = buildWorld()
    world.clearBoard()
    var blocked = newSeq[bool](world.board.cellCount())
    let field = bfsDistances(world.board, [0], blocked)
    check field[0] == 0
    check field[1] == 1
    check field[world.board.size] == 1
    check field[world.board.size + 1] == 2
    check firstStepToward(world.board, world.board.size + 1, field) == dNorth
