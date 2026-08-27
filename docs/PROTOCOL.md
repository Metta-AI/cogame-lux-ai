# lux-ai — wire protocol

## The runtime contract

In: `COGAME_CONFIG_URI`. Out: `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI`, `COGAME_METRICS_URI`.
`COGAME_LOAD_REPLAY_URI` + `/client/replay` drive local replay mode.
`COGAME_HOST` / `COGAME_PORT` bind the server.

## The player socket

`ws://<host>:<port>/player?slot=<i>&token=<t>` — a bad slot or token is a 403.

A seat sends exactly ONE thing that matters: a Sprite v1 chat message (`0x81`)
carrying its registration.

```json
{"type":"register","policy":"<label, <=64 runes>",
 "prompt":"<PLAYER_PROMPT or empty, <=4000 runes>",
 "scripted":"forester"|"prospector"|null}
```

It is re-sent over the first few seconds of received frames, because joins are
slot-sequential and a seat whose slot is not the next open one is not admitted
until the lower slot has joined. The server consumes it as registration, writes
a REDACTED `register` record (policy label and kind, never the prompt) and never
applies it as a bubble.

**A seat sends no inputs.** `fastMode` is true and the server computes every
action from the seat's directive, so the seat only sends the Sprite v1 Ready
packet (`0x85`) after each received frame and otherwise receives. **This game
has no inter-seat channel**: any other chat text from a seat is dropped.

A seat that never registers, or registers with neither field, is
`scripted: "forester"`. A seat that never connects does not end the episode: the
lobby timeout expires, the no-show is reported once to
`COGAME_PLAYER_FAILURE_URI` with the platform's closed payload (exactly
`{"message","failed_policy_index"}`, lowest missing slot only), its side plays
`forester` for the whole episode, and all 360 turns run.

## The spectator socket

`ws://<host>:<port>/global` — no player credentials (they 403). It carries the
bitworld sprite protocol: the baked island as one sprite, per-cell resource,
road and city objects, one chip object per unit, and the broadcast chrome JSON
on the LABEL of reserved sprite id 4090.

### The state JSON

One object per presentation frame, identical live and in replay, and the only
thing the renderer reads. The inherited keys (`t`, `mt`, `ph`, `lob`, `sp`,
`mx`, `st`, `lp`, `sk`, `ff`, `en`, `mm`, `bs`, `teams`, `roster`, `events`,
`lead`, `lulls`, `beats`) are unchanged. lux-ai adds:

```json
{"turn": 214, "turns": 360, "cycle": 5, "night": true, "nightTurn": 4,
 "nightTurns": 10, "size": 16, "res": [212, 54], "coalAt": 50, "uraniumAt": 200,
 "terrain": [{"i": 37, "k": "wood", "a": 288}],
 "roads":   [{"i": 84, "l": 3}],
 "cities":  [{"id": 0, "seat": 0, "fuel": 906, "upkeep": 95, "tiles": [71, 72]}],
 "units":   [{"u": 3, "seat": 0, "k": "worker", "i": 70, "w": 60, "c": 0,
              "r": 0, "cd": 0}],
 "score":   {"cityTiles": [7, 6], "units": [6, 7], "fuel": [967, 1402],
             "leader": 0},
 "dir":     [{"seat": 0, "alias": "RED-alpha", "turn": 210, "stance": "expand",
              "source": "llm", "note": "coal belt at column 3"}]}
```

`terrain` and `roads` are DELTAS (full arrays on the first frame and after any
seek). `i` is always a cell index. `roster[].name` is the seat's REAL policy
name (spectator side); `roster[].alias` is the anonymous in-game name.

### The eleven derived event kinds

`phase` `{to}`; `dawn` `{cycle}`; `dusk` `{cycle, fuel[2], cityTiles[2]}`;
`citybuilt` `{seat, cell, cityId, tiles}`; `citylost` `{seat, cityId, tiles,
cell}`; `unitbuilt` `{seat, kind, cell}`; `unitlost` `{seat, kind, cell,
cause}`; `research` `{seat, kind, points}`; `depleted` `{kind, cell}`;
`directive` `{seat, stance, note}`; `end` `{reason, endRule, cityTiles, winner}`.

### The four beat kinds

`dusk` (<= 9), `research` (<= 4), `citylost` (throttled to one per seat per
night, <= 18) and `end` (1) — at most 32 markers on a 360-turn scrubber. Every
one is a labelled, clickable button that seeks on click.

## The replay

Binary `COWLDLUX`. `tools/replay_summary.py` turns it into one strict-UTF-8
JSON object with Python 3 stdlib only.

| content | carries |
|---|---|
| header | magic `COWLDLUX`, format version, game name `lux-ai`, game version |
| config JSON | seed, num_agents, mapSize, cluster counts and start amounts, every rule constant, `players[].name` (REAL names), slots, fastMode, fullyObservable |
| joins | per seat: name, slot, token |
| input records | `start`, per directive turn per seat the **13 structured bytes**, and the wall-clock `stop` — this game's entire input log, load-bearing, applied before the turn is stepped |
| chats | `register` / `directive` / `fallback` / `budget_guard` / `stop` / `result` |
| hashes | one `gameHash` per tick — the integrity chain the viewer checks |

The map is RE-DERIVED from the seed rather than recorded: it is in `gameHash`
from turn 0, so a divergence surfaces immediately.

## The HTTP routes

`GET /healthz`; `GET /client/player?slot=&token=` (token-checked, and it opens
NO socket — it is the platform's contract probe); `GET /client/global` and
`GET /client/replay` (the broadcast page); `GET /replay-data`. All of them keep
answering for a bounded ~20 s grace after the artifacts are written.
