## The island: the seeded, mirror-symmetric generator, the terrain / amount /
## road arrays, cell<->index helpers and the 4-connected BFS the micro layer
## plans with.
##
## PURE INTEGER. There is no floating point in this file — a CI grep over
## exactly these modules enforces it — which is what makes the native <-> wasm
## hash chain exact by construction.
##
## ONE RNG STREAM. `mapRng` is derived from the episode seed and consumed ONLY
## by `generate` at reset, never again, so nothing a policy does can steer a
## draw and the map is a pure function of (seed, mapSize, cluster config).
## That is the design note's "maps seeded" integrity pin.

import sim_types

type
  MapRng* = object
    ## splitmix64. Explicit rather than `std/random` so the stream is
    ## bit-identical under `--cpu:wasm32` and on the server.
    state: uint64

  Board* = object
    size*: int
    terrain*: seq[Terrain]
    amount*: seq[int]
    road*: seq[int]
    startCell*: array[2, int]
      ## Seat 0's start cell and its mirror, in cell-index form.

proc initMapRng*(seed: int): MapRng =
  MapRng(state: uint64(seed) * 0x9E3779B97F4A7C15'u64 + 0xD1B54A32D192ED03'u64)

proc next(rng: var MapRng): uint64 =
  rng.state = rng.state + 0x9E3779B97F4A7C15'u64
  var z = rng.state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc rand*(rng: var MapRng, maxInclusive: int): int =
  ## Uniform in `0 .. maxInclusive`. Modulo bias is irrelevant at these ranges
  ## and a rejection loop would be one more thing to keep identical in wasm.
  if maxInclusive <= 0:
    return 0
  int(rng.next() mod uint64(maxInclusive + 1))

func cellIndex*(board: Board, x, y: int): int = y * board.size + x
func cellX*(board: Board, cell: int): int = cell mod board.size
func cellY*(board: Board, cell: int): int = cell div board.size
func cellCount*(board: Board): int = board.size * board.size

func inside*(board: Board, x, y: int): bool =
  x >= 0 and y >= 0 and x < board.size and y < board.size

func mirrorCell*(board: Board, cell: int): int =
  let
    x = board.cellX(cell)
    y = board.cellY(cell)
  y * board.size + (board.size - 1 - x)

func chebyshev*(ax, ay, bx, by: int): int =
  max(abs(ax - bx), abs(ay - by))

const
  StepDx*: array[4, int] = [0, 1, 0, -1]      ## north, east, south, west
  StepDy*: array[4, int] = [-1, 0, 1, 0]

func stepDirection*(index: int): Direction =
  case index
  of 0: dNorth
  of 1: dEast
  of 2: dSouth
  else: dWest

func directionIndex*(dir: Direction): int =
  case dir
  of dNorth: 0
  of dEast: 1
  of dSouth: 2
  of dWest: 3
  of dCenter: -1

iterator orthogonal*(board: Board, cell: int): int =
  ## The up-to-four orthogonal neighbours of `cell`, in the FIXED order
  ## north, east, south, west. Every tie-break in the rules depends on this
  ## order being stable.
  let
    x = board.cellX(cell)
    y = board.cellY(cell)
  for i in 0 ..< 4:
    let
      nx = x + StepDx[i]
      ny = y + StepDy[i]
    if board.inside(nx, ny):
      yield ny * board.size + nx

func startAmount*(kind: Terrain, woodStart, coalStart, uraniumStart: int): int =
  case kind
  of tWood: woodStart
  of tCoal: coalStart
  of tUranium: uraniumStart
  of tEmpty: 0

func clusterSize(kind: Terrain): int =
  case kind
  of tWood: 6
  of tCoal: 3
  of tUranium: 2
  of tEmpty: 0

func minSeparation(kind: Terrain): int =
  case kind
  of tWood: 3
  of tCoal: 4
  of tUranium: 5
  of tEmpty: 0

proc place(
  board: var Board,
  rng: var MapRng,
  centres: var seq[int],
  kind: Terrain,
  count, size, minSep, amount: int
) =
  ## The design note's `place(kind, count, size, minSep)`, verbatim: rejection
  ## sample a cluster centre in the LEFT HALF at least `sep` Chebyshev from
  ## every already-placed centre, relaxing `sep` every 200 attempts so the
  ## sampler always terminates, then flood the first `size` empty cells in the
  ## fixed neighbour order.
  let half = board.size div 2
  for _ in 0 ..< count:
    var
      sep = minSep
      attempts = 0
      cx = 1
      cy = 1
    while true:
      cx = 1 + rng.rand(half - 2)
      cy = 1 + rng.rand(board.size - 3)
      inc attempts
      let cell = cy * board.size + cx
      var ok = board.terrain[cell] == tEmpty
      if ok:
        for centre in centres:
          if chebyshev(cx, cy, board.cellX(centre), board.cellY(centre)) < sep:
            ok = false
            break
      if ok:
        break
      if attempts mod 200 == 0:
        sep = max(2, sep - 1)
    let centre = cy * board.size + cx
    centres.add(centre)
    # Breadth-first over the eight neighbours in the fixed order
    # [up, right, down, left, up-left, up-right, down-left, down-right],
    # taking cells that are inside the LEFT half and still empty.
    const
      Dx = [0, 1, 0, -1, -1, 1, -1, 1]
      Dy = [-1, 0, 1, 0, -1, -1, 1, 1]
    var
      chosen: seq[int] = @[centre]
      queue: seq[int] = @[centre]
      head = 0
    board.terrain[centre] = kind
    board.amount[centre] = amount
    while head < queue.len and chosen.len < size:
      let current = queue[head]
      inc head
      let
        x = board.cellX(current)
        y = board.cellY(current)
      for i in 0 ..< 8:
        if chosen.len >= size:
          break
        let
          nx = x + Dx[i]
          ny = y + Dy[i]
        if nx < 0 or ny < 0 or nx >= half or ny >= board.size:
          continue
        let neighbour = ny * board.size + nx
        if board.terrain[neighbour] != tEmpty:
          continue
        board.terrain[neighbour] = kind
        board.amount[neighbour] = amount
        chosen.add(neighbour)
        queue.add(neighbour)

proc pickStartCell(board: Board): int =
  ## The first `empty` left-half cell with at least two empty orthogonal
  ## neighbours whose Chebyshev distance from the half's centre is minimal;
  ## ties by lowest cell index.
  let
    half = board.size div 2
    centreX = board.size div 4
    centreY = board.size div 2
  var
    best = -1
    bestDistance = high(int)
  for y in 0 ..< board.size:
    for x in 0 ..< half:
      let cell = y * board.size + x
      if board.terrain[cell] != tEmpty:
        continue
      var free = 0
      for neighbour in board.orthogonal(cell):
        if board.terrain[neighbour] == tEmpty:
          inc free
      if free < 2:
        continue
      let distance = chebyshev(x, y, centreX, centreY)
      if distance < bestDistance:
        bestDistance = distance
        best = cell
  if best < 0:
    # Degenerate island (every left-half cell carries a resource): fall back to
    # the lowest-index cell so reset can never fail. Unreachable at every
    # shipped cluster count; the board test sweeps 10 000 seeds for it.
    best = 0
  best

proc generateBoard*(
  size, seed, woodClusters, coalClusters, uraniumClusters: int,
  woodStart, coalStart, uraniumStart: int
): Board =
  ## Generates the whole island from `seed`, over the LEFT HALF only, then
  ## mirrors it about the vertical midline. `tests/test_lux_board.nim` asserts
  ## the result is exactly mirror-symmetric in terrain kind AND amount at
  ## reset, for 10 000 seeds and both map sizes.
  result.size = size
  result.terrain = newSeq[Terrain](size * size)
  result.amount = newSeq[int](size * size)
  result.road = newSeq[int](size * size)
  var
    rng = initMapRng(seed)
    centres: seq[int] = @[]
  result.place(rng, centres, tWood, woodClusters,
    clusterSize(tWood), minSeparation(tWood), woodStart)
  result.place(rng, centres, tCoal, coalClusters,
    clusterSize(tCoal), minSeparation(tCoal), coalStart)
  result.place(rng, centres, tUranium, uraniumClusters,
    clusterSize(tUranium), minSeparation(tUranium), uraniumStart)
  let start = result.pickStartCell()
  result.startCell[0] = start
  result.startCell[1] = result.mirrorCell(start)
  for y in 0 ..< size:
    for x in 0 ..< size div 2:
      let cell = y * size + x
      let mirror = result.mirrorCell(cell)
      result.terrain[mirror] = result.terrain[cell]
      result.amount[mirror] = result.amount[cell]
      result.road[mirror] = result.road[cell]

func mirrorSymmetric*(board: Board): bool =
  ## Terrain KIND symmetry only — amounts diverge the moment anyone mines.
  for cell in 0 ..< board.cellCount():
    if board.terrain[cell] != board.terrain[board.mirrorCell(cell)]:
      return false
  true

proc bfsDistances*(
  board: Board, sources: openArray[int], blocked: openArray[bool]
): seq[int] =
  ## Distance in steps from the nearest source to every reachable cell, -1
  ## where unreachable. Neighbours are expanded in the fixed order
  ## north, east, south, west, so the frontier order — and therefore every
  ## first step derived from it — is unique.
  result = newSeq[int](board.cellCount())
  for i in 0 ..< result.len:
    result[i] = -1
  var
    queue = newSeqOfCap[int](board.cellCount())
    head = 0
  for source in sources:
    if source >= 0 and source < result.len and not blocked[source] and
        result[source] < 0:
      result[source] = 0
      queue.add(source)
  while head < queue.len:
    let current = queue[head]
    inc head
    for neighbour in board.orthogonal(current):
      if blocked[neighbour] or result[neighbour] >= 0:
        continue
      result[neighbour] = result[current] + 1
      queue.add(neighbour)

proc firstStepToward*(
  board: Board, fromCell: int, field: openArray[int]
): Direction =
  ## The first move of the unique shortest path from `fromCell` down a BFS
  ## distance field (built with the goal as the source). Ties break in the
  ## fixed neighbour order, so the path a browser re-derives is the path the
  ## server walked.
  if field[fromCell] == 0:
    return dCenter
  let
    x = board.cellX(fromCell)
    y = board.cellY(fromCell)
  var
    best = -1
    bestDistance = high(int)
  for i in 0 ..< 4:
    let
      nx = x + StepDx[i]
      ny = y + StepDy[i]
    if not board.inside(nx, ny):
      continue
    let
      neighbour = ny * board.size + nx
      distance = field[neighbour]
    if distance < 0:
      continue
    if distance < bestDistance:
      bestDistance = distance
      best = i
  if best < 0 or (field[fromCell] >= 0 and bestDistance >= field[fromCell]):
    return dCenter
  stepDirection(best)
