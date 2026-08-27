# lux-ai — the rules

A port of the **Lux AI Challenge Season 1** rules onto a 16 x 16 mirrored grid.
Two sides gather wood, coal and uranium, spend research to unlock the better
fuels, grow cities out of city tiles, and every ten turns the sun goes down and
each city must pay its light bill or die on the spot. **Most city tiles standing
at turn 360 wins.**

## The clock

- One tick is one Lux turn. `maxTurns` is **360** (`duel`, `scarcity`) or
  **200** (`skirmish`).
- A **cycle** is `cycleLength` **40** turns: `turn mod 40 < 30` is **day**,
  `turn mod 40 >= 30` is **night**. Nine full cycles in 360 turns.
- A **directive turn** is every `directiveEvery` = **10** turns, beginning at
  turn 0: 36 directive turns per episode. Ten divides the 30/10 cycle exactly,
  so a seat is always asked for a new directive **on the turn the sun sets**.

## The board

`mapSize` is even and is 16 in the default variant. The map is generated from
the episode seed and is **perfectly mirror-symmetric** about the vertical
midline; seat 0 owns the left half, seat 1 the right. Symmetry is the integrity
pin: neither side can be dealt a better island.

## The turn, in order

Every turn runs these steps and nothing else mutates the world. An action that
is illegal at the moment it is evaluated is **discarded and costs no cooldown**.

1. **Directive install** (directive turns only).
2. **Order compilation** — the deterministic micro layer emits at most one
   action per unit and per city tile whose `cooldownTenths == 0`.
3. **City-tile actions**, ascending tile index, seat 0 then seat 1:
   `research` (+1 point), `build_worker` / `build_cart` (only while
   `units < cityTiles`). Any accepted action costs the tile 100 cooldown tenths.
4. **Transfers**, ascending giver unit id, to an orthogonally adjacent unit of
   the same team.
5. **City building**, ascending unit id. A worker on `empty` terrain with no
   city tile and `wood + coal + uranium >= 100` spends exactly 100 resource
   units cheapest-first and plants a tile. Two opposing workers on one cell:
   neither builds. Two friendly: the lower unit id builds. The new tile merges
   into the lowest adjacent same-team city id, fuels summing; road level 6.
6. **Movement** — illegal targets discarded; a monotone blocking-and-contention
   **fixed point** decides who actually moves; survivors apply simultaneously;
   a cart paves the empty cell it lands on.
7. **Resource collection** — only workers, wood then coal then uranium, over
   every tile of that kind in ascending index. Rates 20 / 5 / 2 per adjacent
   worker per tile; when a tile cannot pay everyone, the amount is split evenly
   with the first `amount mod |M|` workers taking one extra. Coal needs 50
   research points, uranium 200.
8. **Deposit** — every unit on a friendly city tile empties its whole cargo into
   that city at 1 / 10 / 40 fuel per unit, every turn, day and night.
9. **Night burn** (night turns only). Cities first: `upkeep = 23 * tiles -
   5 * adjacentPairs`; a city that cannot pay is **destroyed entirely**. Units
   second: a unit on a surviving friendly city tile pays nothing, every other
   unit burns 4 (worker) or 10 (cart) fuel from its own cargo, and one that
   cannot pay dies.
10. **Cooldowns** — `cooldownTenths -= 10 + 2 * road`; city tiles -10.
11. **Wood regrowth** — every wood tile with `0 < amount < 500` grows by
    `max(1, amount div 50)`. A tile mined to exactly 0 **never comes back**.
12. **Sim guard** — `checkLuxInvariants()`.
13. **Hash and end check**.

## Winning

Measured at the final turn, first difference decides: more city tiles, then more
units, then more banked fuel, else a tie. The league score is the match point:
1.0 / 0.5 / 0.0, and `scores[0] + scores[1] == 1.0` on every episode.

## Documented divergences from `Lux-Design-S1`

This is an adaptation of a public specification, not a reproduction of the
JavaScript engine. No test compares a trajectory to a reference implementation.

| lux-ai | Lux S1 |
|---|---|
| a new seeded mirror-symmetric map generator | S1's procedural generator |
| integer wood regrowth `+max(1, amount div 50)` | x1.02 per turn |
| cooldown in **tenths**, recovery `10 + 2 x road` | fractional `1 + 0.2 x road` |
| map sizes 12 and 16 only | S1 also rolls 24 and 32 |
| **no pillage** | workers may destroy roads |
| a directive every 10 turns compiled by a deterministic micro layer | per-unit orders every turn |

## Two amendments to the design note's own rule order

Both are recorded here because they change how a game plays, and both exist
because the literal reading produces a dead game:

1. **Production before research.** The design note orders the city-tile rules
   research-first. S1's unit cap (`units < cityTiles`) makes that
   self-defeating at the opening: a side with one tile and one worker spends
   every tile action of the first hundred turns on research points and starves,
   because a research point does not mine wood and the night bill does not wait.
   Research therefore YIELDS while the side is both under the unit cap and below
   its directive's unit target — the exact trade the system prompt describes to
   the model.
2. **`prospector` carries `forester`'s night guard, and plants a seed blob
   first.** The note's `prospector` researches to 200 before it expands; with
   one city tile earning one point every ten turns that is 2000 turns, so it
   never moves. It now expands to `prospectorSeedTiles` tiles first and, like
   `forester`, drops to `stance: "fuel"` whenever one of its cities is inside
   `foresterFuelNights` nights of starving. Without the guard it is wiped out in
   night 1 on most seeds, which is a dead filler rather than a control.

## The scripted baselines

**`forester`** (`PLAYER_SCRIPTED=forester`) — the certification player, the
per-turn LLM fallback, the driver of a no-show seat, and the published default.
Wood until coal is researched, expand unless a city is inside
`foresterFuelNights` nights of starving.

**`prospector`** (`PLAYER_SCRIPTED=prospector`) — the second filler,
deliberately different in shape: it buys the fuel ladder early and pays for it
in tiles. `forester` beats it at the pinned seed, which is a real bar for a
champion to clear.

Both emit the same directive object an LLM does, through the same validator,
and neither ever writes a `note`. Their tuned numbers are the pick from
`tools/tune_baselines.nim`, pinned in `tools/ci/baseline_tuning.json`.
