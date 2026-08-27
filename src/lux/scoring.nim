## The winner ladder, `scores`, `win`, `winner` and the per-seat counters.
##
## SIGN: higher is better and NO term is ever negative. `scores[0] +
## scores[1] == 1.0` on every episode without exception — a strict zero-sum
## duel, which is the integrity property the idea asks for and what the
## platform's Elo (1000 start, K 32) wants to eat.
##
## PURE INTEGER: the ladder resolves over `{0, 1, 2}` match points and the
## 0.0 / 0.5 / 1.0 floats are produced at SERIALISATION time only, never
## inside the sim.

import cities, sim_state, sim_types, units

type
  Standing* = object
    cityTiles*: array[2, int]
    units*: array[2, int]
    fuel*: array[2, int64]
    research*: array[2, int]

  Outcome* = object
    points*: array[2, int]   ## 2 = win, 1 = tie, 0 = loss
    winner*: int             ## seat index, or -1 on a tie

func standing*(world: World): Standing =
  for seat in 0 .. 1:
    let team = Team(seat)
    result.cityTiles[seat] = world.cities.tileCount(team)
    result.units[seat] = world.units.countOf(team)
    result.fuel[seat] = world.cities.totalFuel(team)
    result.research[seat] = world.researchPoints[seat]

func settle*(standing: Standing): Outcome =
  ## The ladder, first difference decides:
  ##   1. more city tiles   (the idea's "most city tiles at the end wins")
  ##   2. more living units (S1's own first tiebreak)
  ##   3. more banked fuel  (S1's second tiebreak)
  ##   4. otherwise a tie
  var winner = -1
  if standing.cityTiles[0] != standing.cityTiles[1]:
    winner = if standing.cityTiles[0] > standing.cityTiles[1]: 0 else: 1
  elif standing.units[0] != standing.units[1]:
    winner = if standing.units[0] > standing.units[1]: 0 else: 1
  elif standing.fuel[0] != standing.fuel[1]:
    winner = if standing.fuel[0] > standing.fuel[1]: 0 else: 1
  result.winner = winner
  if winner < 0:
    result.points = [1, 1]
  elif winner == 0:
    result.points = [2, 0]
  else:
    result.points = [0, 2]

func scoreOf*(outcome: Outcome, seat: int): float =
  ## The league's match point. Produced HERE, at serialisation time, from the
  ## integer ladder — no float ever enters the sim.
  case outcome.points[seat]
  of 2: 1.0
  of 1: 0.5
  else: 0.0

func winOf*(outcome: Outcome, seat: int): bool =
  outcome.points[seat] == 2

func eliminated*(world: World, seat: int): bool =
  ## A seat with zero city tiles AND zero units has nothing left that can act.
  ## Nine nights is long enough that a total wipe-out is a real outcome and
  ## watching an empty board for 200 more turns is not.
  world.cities.tileCount(Team(seat)) == 0 and world.units.countOf(Team(seat)) == 0
