## City tiles and cities: the per-cell tile arrays, the city union (build,
## merge, destroy), `upkeep`, `adjacentPairs` and the survival projection the
## observation reports.
##
## PURE INTEGER apart from `city.fuel`, which is `int64` on purpose: a cart of
## uranium is 80 000 fuel and a 360-turn game banks six figures, while Nim's
## `int` is 32-bit under `--cpu:wasm32`.

import board, sim_types

type
  City* = object
    id*: int
    team*: Team
    fuel*: int64
    cells*: seq[int]     ## always sorted ascending by cell index.

  Cities* = object
    list*: seq[City]     ## living cities only, sorted by ascending id.
    nextId*: int
    cityOfCell*: seq[int]   ## city id, or -1
    teamOfCell*: seq[int]   ## 0/1, or -1 where there is no tile
    cooldownOfCell*: seq[int]

proc initCities*(cellCount: int): Cities =
  result.nextId = 0
  result.cityOfCell = newSeq[int](cellCount)
  result.teamOfCell = newSeq[int](cellCount)
  result.cooldownOfCell = newSeq[int](cellCount)
  for i in 0 ..< cellCount:
    result.cityOfCell[i] = -1
    result.teamOfCell[i] = -1

func hasTile*(cities: Cities, cell: int): bool =
  cities.cityOfCell[cell] >= 0

func tileTeam*(cities: Cities, cell: int): int =
  cities.teamOfCell[cell]

func indexOfCity*(cities: Cities, id: int): int =
  for i, city in cities.list:
    if city.id == id:
      return i
  -1

func tileCount*(cities: Cities, team: Team): int =
  for city in cities.list:
    if city.team == team:
      result += city.cells.len

func cityCount*(cities: Cities, team: Team): int =
  for city in cities.list:
    if city.team == team:
      inc result

func totalFuel*(cities: Cities, team: Team): int64 =
  for city in cities.list:
    if city.team == team:
      result += city.fuel

func adjacentPairs*(city: City, board: Board): int =
  ## Unordered orthogonally-adjacent pairs of tiles INSIDE this city. Counted
  ## once per pair (only the east and south neighbours are examined).
  for cell in city.cells:
    let
      x = board.cellX(cell)
      y = board.cellY(cell)
    if x + 1 < board.size and (y * board.size + x + 1) in city.cells:
      inc result
    if y + 1 < board.size and ((y + 1) * board.size + x) in city.cells:
      inc result

func upkeep*(city: City, board: Board, perTile, discount: int): int =
  ## `23 * tiles - 5 * adjacentPairs`, floored at 0. A 6-tile line pays 113 a
  ## turn; a 3x3 blob of 9 pays 147 where 9 separate tiles pay 207 — which is
  ## why the micro grows a blob.
  max(0, perTile * city.cells.len - discount * city.adjacentPairs(board))

func turnsOfFuel*(city: City, board: Board, perTile, discount: int): int =
  let bill = city.upkeep(board, perTile, discount)
  if bill <= 0:
    return 999
  int(min(999'i64, city.fuel div int64(bill)))

proc sortedInsert(cells: var seq[int], cell: int) =
  var i = 0
  while i < cells.len and cells[i] < cell:
    inc i
  cells.insert(cell, i)

proc addTile*(
  cities: var Cities, board: Board, team: Team, cell: int
): tuple[cityId: int, merged: bool] {.discardable.} =
  ## Places one city tile and joins it to the union of orthogonally adjacent
  ## same-team tiles: touching cities MERGE into the lowest city id with their
  ## fuels summed; touching nothing forms a new city with `fuel = 0`.
  var neighbours: seq[int] = @[]
  for neighbour in board.orthogonal(cell):
    let id = cities.cityOfCell[neighbour]
    if id >= 0 and cities.teamOfCell[neighbour] == ord(team) and
        id notin neighbours:
      neighbours.add(id)
  if neighbours.len == 0:
    let id = cities.nextId
    inc cities.nextId
    cities.list.add(City(id: id, team: team, fuel: 0, cells: @[cell]))
    cities.cityOfCell[cell] = id
    cities.teamOfCell[cell] = ord(team)
    cities.cooldownOfCell[cell] = 0
    return (id, false)
  var keep = neighbours[0]
  for id in neighbours:
    if id < keep:
      keep = id
  let keepIndex = cities.indexOfCity(keep)
  cities.list[keepIndex].cells.sortedInsert(cell)
  cities.cityOfCell[cell] = keep
  cities.teamOfCell[cell] = ord(team)
  cities.cooldownOfCell[cell] = 0
  var merged = false
  for id in neighbours:
    if id == keep:
      continue
    merged = true
    let index = cities.indexOfCity(id)
    if index < 0:
      continue
    let absorbed = cities.list[index]
    cities.list[keepIndex].fuel += absorbed.fuel
    for other in absorbed.cells:
      cities.list[keepIndex].cells.sortedInsert(other)
      cities.cityOfCell[other] = keep
    cities.list.delete(index)
  (keep, merged)

proc destroyCity*(cities: var Cities, id: int): seq[int] =
  ## Removes every tile of one city at once and returns the cells it freed.
  ## The cells keep their road level 6 — a burnt city leaves its pavement.
  let index = cities.indexOfCity(id)
  if index < 0:
    return @[]
  result = cities.list[index].cells
  for cell in result:
    cities.cityOfCell[cell] = -1
    cities.teamOfCell[cell] = -1
    cities.cooldownOfCell[cell] = 0
  cities.list.delete(index)

func largestCityIndex*(cities: Cities, team: Team): int =
  ## The team's largest city, ties by lowest city id. -1 when it owns none.
  result = -1
  var best = -1
  for i, city in cities.list:
    if city.team != team:
      continue
    if city.cells.len > best:
      best = city.cells.len
      result = i

func connectedComponent*(city: City, board: Board): bool =
  ## Every city must be ONE orthogonally-connected component of same-team
  ## tiles. Asserted by the sim guard each turn.
  if city.cells.len <= 1:
    return true
  var
    seen: seq[int] = @[city.cells[0]]
    queue: seq[int] = @[city.cells[0]]
    head = 0
  while head < queue.len:
    let current = queue[head]
    inc head
    for neighbour in board.orthogonal(current):
      if neighbour in city.cells and neighbour notin seen:
        seen.add(neighbour)
        queue.add(neighbour)
  seen.len == city.cells.len
