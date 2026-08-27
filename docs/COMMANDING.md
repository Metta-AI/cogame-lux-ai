# Writing a Lux directive prompt

A policy is just a prompt. Your prompt is pasted under a
"GUIDANCE FROM YOUR OPERATOR" heading in front of a JSON observation, every ten
turns, and the model's reply is one strategy object. A deterministic controller
executes that object for the next ten turns: it assigns every worker to the best
tile of your chosen resource, walks them home to deposit, plants city tiles when
they are full, drives your carts and tells your city tiles what to build.

**You never move units.** Write strategy, not micro.

## What you are choosing

```json
{"stance":"expand|fuel|research|contest|turtle",
 "mine":["wood","coal","uranium"],
 "research":"none|coal|uranium|always",
 "build":"auto|city|worker|cart",
 "workers":6, "carts":1,
 "focus":[x,y] or null,
 "night":"shelter|mine|haul",
 "note":"<=160 chars, spectators only"}
```

- `stance` **expand** plants tiles near your cities and near `focus`;
  **fuel** walks full workers home instead; **research** is `fuel` plus city
  tiles that keep researching; **contest** plants next to the resource tiles
  nearest the opponent; **turtle** hauls everything into your largest city.
- `mine` is the ORDER your workers prefer, not a filter.
- `focus` is where the expansion effort aims. Null lets the micro pick.
- `note` is the only thing you say. It reaches the match feed and the replay and
  the other side NEVER sees it.

## The three things that decide games

1. **The night bill.** Each city pays `23 x tiles - 5 x touching pairs` EVERY
   night turn, ten turns a night. A city that cannot pay is destroyed entirely,
   every tile, that instant. Read `turns_of_fuel` and `survives_tonight` for
   every city in `city_list` before anything else.
2. **Compactness.** Nine tiles in a 3x3 block pay 147 a turn; nine separate
   tiles pay 207. Setting `focus` next to your largest city is worth more than
   any other single field.
3. **The research trade.** A city tile spends its whole turn to earn ONE
   research point, so research literally costs you workers. Coal at 50 points is
   ten wood per unit and usually pays; uranium at 200 is six cycles of a tile
   doing nothing.

## What a good prompt looks like

- Give the model a **cycle-1 opening** in concrete field values.
- Give it a **trigger** it can read off the observation
  ("if any city shows `survives_tonight` false, switch to `fuel`").
- Give it a **stopping rule** for research.
- Tell it what to do when it is behind.

Both shipped champions do all four; read them in
`scripts/champion_prompts.json` and in the design note's Decisions section.

## What the observation gives you

Three ASCII layers (terrain, cities, units) of exactly `mapSize` lines, a
`resources` block per kind with `tiles_left` / `amount_left` / `yours` /
`theirs` / `researched` and the six richest tiles, a `yours` block with your
research, tile and unit counts, cargo, and a per-city list carrying
`upkeep_per_night_turn`, `survives_tonight` and `turns_of_fuel`, the same public
block for the opponent, the standing, your last directive, and a one-line
`how_it_went` the engine writes.

Lux Season 1 is FULLY OBSERVABLE and so is this port. Hidden from you: the
opponent's directive and note (ever), every prompt, the seed, and any seat's
fallback statistics.
