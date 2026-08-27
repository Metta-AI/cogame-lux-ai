#!/usr/bin/env python3
"""Generate `coworld_manifest_template.json`.

The manifest inlines the README and all three docs pages as TEXT (the platform
validator wants `{"type":"text","value":…}` objects, never bare strings or
URIs), so it has to be generated from those files or the two drift. Run it after
any doc or schema change and commit the output:

    python3 scripts/build_manifest.py

`tests/test_lux_manifest.nim` asserts every pin this file is responsible for.
"""

from __future__ import annotations

import collections
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(*parts: str) -> str:
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as handle:
        return handle.read()


def text(value: str) -> dict:
    return {"type": "text", "value": value}


BASE = {
    "players": [{"name": "Red"}, {"name": "Blue"}],
    "num_agents": 2, "minPlayers": 2, "teams": 2, "cogsPerTeam": 1,
    "mapSize": 16, "woodClusters": 4, "coalClusters": 2, "uraniumClusters": 1,
    "woodStart": 300, "coalStart": 400, "uraniumStart": 325,
    "maxTurns": 360, "cycleLength": 40, "dayLength": 30, "directiveEvery": 10,
    "attempt1Ms": 7000, "retryMs": 3000, "turnBudgetMs": 11000,
    "turnSpacingMs": 6000, "wallClockBudgetSeconds": 660,
    "lobbyJoinTimeoutTicks": 2400, "startWaitTicks": 48, "gameOverTicks": 72,
    "fastMode": True, "showPlayerLabels": False, "fullyObservable": True,
    "seed": 1734029581,
}
# NOTE: no `tokens` array appears in ANY game_config — matriculate rejects
# "game_config must not include runner-managed tokens" — while `config_schema`
# keeps REQUIRING it, because the runner injects it.


def variant(vid: str, name: str, description: str, **override) -> dict:
    config = dict(BASE)
    config.update(override)
    return {"id": vid, "name": name, "description": description,
            "game_config": config}


def num(default: int, **bounds) -> dict:
    field = {"type": "integer", "default": default}
    field.update(bounds)
    return field


def arr2(item: dict) -> dict:
    return {"type": "array", "minItems": 2, "maxItems": 2, "items": item}


CONFIG_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["tokens", "players"],
    "properties": {
        "tokens": {
            "type": "array", "items": {"type": "string"},
            "minItems": 2, "maxItems": 2,
            "description": "Runner-injected seat tokens. Required here because "
                           "the runner supplies them; never present in a "
                           "game_config in this manifest.",
        },
        "players": {
            "type": "array", "minItems": 2, "maxItems": 2,
            "items": {"type": "object", "additionalProperties": False,
                      "properties": {"name": {"type": "string"}}},
        },
        "slots": {"type": "array", "minItems": 0, "maxItems": 2,
                  "items": {"type": "integer"}},
        "num_agents": num(2, minimum=2, maximum=2),
        "minPlayers": num(2, minimum=2, maximum=2),
        "teams": num(2, minimum=2, maximum=2),
        "cogsPerTeam": num(1, minimum=1, maximum=1),
        "seed": num(1734029581, minimum=0),
        "mapSize": {"type": "integer", "enum": [12, 16], "default": 16},
        "woodClusters": num(4, minimum=0, maximum=16),
        "coalClusters": num(2, minimum=0, maximum=16),
        "uraniumClusters": num(1, minimum=0, maximum=16),
        "woodStart": num(300, minimum=1, maximum=2000),
        "coalStart": num(400, minimum=1, maximum=2000),
        "uraniumStart": num(325, minimum=1, maximum=2000),
        "maxTurns": num(360, minimum=1, maximum=1000),
        "cycleLength": num(40, minimum=2, maximum=200),
        "dayLength": num(30, minimum=1, maximum=199),
        "directiveEvery": num(10, minimum=1, maximum=100),
        "cityCost": num(100, minimum=1, maximum=1000),
        "workerCargo": num(100, minimum=1, maximum=10000),
        "cartCargo": num(2000, minimum=1, maximum=100000),
        "woodRate": num(20, minimum=0, maximum=1000),
        "coalRate": num(5, minimum=0, maximum=1000),
        "uraniumRate": num(2, minimum=0, maximum=1000),
        "coalResearch": num(50, minimum=0, maximum=10000),
        "uraniumResearch": num(200, minimum=0, maximum=10000),
        "cityUpkeepPerTile": num(23, minimum=0, maximum=1000),
        "cityAdjacencyDiscount": num(5, minimum=0, maximum=1000),
        "workerUpkeep": num(4, minimum=0, maximum=1000),
        "cartUpkeep": num(10, minimum=0, maximum=1000),
        "workerCooldown": num(20, minimum=0, maximum=1000),
        "cartCooldown": num(30, minimum=0, maximum=1000),
        "cityCooldown": num(100, minimum=0, maximum=1000),
        "maxRoad": num(6, minimum=0, maximum=6),
        "attempt1Ms": num(7000, minimum=0, maximum=60000),
        "retryMs": num(3000, minimum=0, maximum=60000),
        "turnBudgetMs": num(11000, minimum=1, maximum=60000),
        "turnSpacingMs": num(6000, minimum=0, maximum=60000),
        "wallClockBudgetSeconds": num(660, minimum=1, maximum=720),
        "lobbyJoinTimeoutTicks": num(2400, minimum=1, maximum=100000),
        "startWaitTicks": num(48, minimum=0, maximum=100000),
        "gameOverTicks": num(72, minimum=0, maximum=100000),
        "fastMode": {"type": "boolean", "default": True},
        "showPlayerLabels": {"type": "boolean", "default": False},
        "fullyObservable": {"type": "boolean", "default": True},
        "model": {"type": "string", "default": ""},
        "maxOutputTokens": num(900, minimum=1, maximum=8192),
    },
}

RESULTS_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["names", "scores", "win", "reason", "endRule", "cityTiles",
                 "turnsPlayed"],
    "properties": {
        "names": arr2({"type": "string"}),
        "aliases": arr2({"type": "string"}),
        "scores": arr2({"type": "number"}),
        "win": arr2({"type": "boolean"}),
        "winner": {"type": ["integer", "null"], "minimum": 0, "maximum": 1},
        "reason": {"type": "string",
                   "enum": ["complete", "deadline", "fault"]},
        "endRule": {"type": "string",
                    "enum": ["full_time", "eliminated", "wall_clock",
                             "sim_fault", "host_error"]},
        "cityTiles": arr2({"type": "integer"}),
        "units": arr2({"type": "integer"}),
        "fuel": arr2({"type": "integer"}),
        "research": arr2({"type": "integer"}),
        "cityTilesBuilt": arr2({"type": "integer"}),
        "cityTilesLost": arr2({"type": "integer"}),
        "unitsBuilt": arr2({"type": "integer"}),
        "unitsLost": arr2({"type": "integer"}),
        "resourcesMined": arr2({"type": "array", "minItems": 3, "maxItems": 3,
                                "items": {"type": "integer"}}),
        "nightsSurvived": arr2({"type": "integer"}),
        "blockedMoves": arr2({"type": "integer"}),
        "turnsPlayed": {"type": "integer"},
        "mapSize": {"type": "integer"},
        "seed": {"type": "integer"},
        "policyKinds": arr2({"type": "string"}),
        "llmTurns": arr2({"type": "integer"}),
        "fallbackTurns": arr2({"type": "integer"}),
        "directivesRejected": arr2({"type": "integer"}),
        "deadSeats": arr2({"type": "boolean"}),
        "stopDetail": {"type": "string"},
    },
}

PLAYER_RESOURCES = {"requests": {"cpu": "200m", "memory": "128Mi"},
                    "limits": {"cpu": "1"}}
SOURCE_URL = "https://github.com/Metta-AI/cogame-lux-ai/tree/main"

PLAYER_PROTOCOL = """The seat websocket is ws://<host>:<port>/player?slot=<i>&token=<t>; a bad slot or
token is a 403. A seat sends exactly ONE thing that matters: a Sprite v1 chat
message (0x81) carrying its registration,

  {"type":"register","policy":"<label, <=64 runes>",
   "prompt":"<PLAYER_PROMPT or empty, <=4000 runes>",
   "scripted":"forester"|"prospector"|null}

re-sent over the first few seconds of received frames, because joins are
slot-sequential and a seat whose slot is not the next open one is not admitted
until the lower slot has joined. The server consumes it as registration, writes
a REDACTED `register` record (policy label and kind, never the prompt) and never
applies it as a bubble.

A SEAT SENDS NO INPUTS. fastMode is true and the server computes every action
from the seat's directive, so the seat only sends the Sprite v1 Ready packet
(0x85) after each received frame and otherwise receives. This game has NO
inter-seat channel: any other chat text from a seat is dropped.

The frame a seat receives is the same sprite-protocol stream a spectator gets.
A seat's OBSERVATION is not on the socket at all: the LLM call is made by the
GAME container, which builds the observation server-side, so a seat container
never sees game state and never needs an API key.

A seat that never registers, or registers with neither field, is
scripted "forester". A seat that never connects does not end the episode: the
lobby timeout expires, the no-show is reported once to
COGAME_PLAYER_FAILURE_URI with exactly {"message","failed_policy_index"}, its
side plays forester for the whole episode, and all 360 turns run."""

GLOBAL_PROTOCOL = """The spectator websocket is ws://<host>:<port>/global (player credentials 403).
It carries the bitworld sprite protocol: the baked island as one sprite, per-cell
resource / road / city objects, one chip object per unit, and the broadcast
chrome JSON on the LABEL of reserved sprite id 4090.

The state JSON, one object per presentation frame, identical live and in replay,
is the only thing the renderer reads. Inherited keys: t, mt, ph, lob, sp, mx, st,
lp, sk, ff, en, mm, bs, teams, roster, events, lead, lulls, beats. lux-ai adds
turn, turns, cycle, cycles, night, nightTurn, nightTurns, dayLength, size, res,
coalAt, uraniumAt, terrain (delta: [{i,k,a}]), roads (delta: [{i,l}]), cities
([{id,seat,fuel,upkeep,tiles}]), units ([{u,seat,k,i,w,c,r,cd}]), score and dir.
roster[].name is the seat's REAL policy name (spectator side only);
roster[].alias is the anonymous in-game name a seat itself sees.

Eleven derived event kinds: phase, dawn, dusk, citybuilt, citylost, unitbuilt,
unitlost, research, depleted, directive, end.

Four scrubber beat kinds, all bounded by construction: dusk (<=9), research
(<=4), citylost (throttled to one per seat per night, <=18) and end (1) — at
most 32 markers on a 360-turn scrubber, each a labelled clickable button.

Replay records: `register`, `directive`, `fallback`, `budget_guard`, `stop` and
`result` as chat records; the 13 structured directive bytes, the game start and
the wall-clock stop as INPUT records, which are load-bearing and re-applied
before the turn they belong to is stepped."""


def main() -> int:
    manifest = collections.OrderedDict()
    manifest["$schema"] = "https://softmax.com/schemas/coworld-manifest.json"
    manifest["tags"] = ["lux", "rts", "economy", "zero-sum", "grid", "port"]
    manifest["episode_timeout_minutes"] = 20
    manifest["game"] = {
        "name": "lux-ai",
        "owner": "daveey@softmax.com",
        "description":
            "Lux AI Season 1 on a seeded, mirror-symmetric 16x16 island: two "
            "sides gather wood, coal and uranium, spend research to unlock the "
            "better fuels, and every ten turns the sun goes down and each city "
            "must pay its light bill or die on the spot. Most city tiles "
            "standing at turn 360 wins.",
        "runnable": {
            "type": "game",
            "image": "{{LUX_AI_IMAGE}}",
            "run": ["/bin/lux-ai"],
            # WITHOUT this env entry the hosted game container never sees the
            # coworld secret and every league episode silently plays scripted
            # (the hive 2026-08-23 scar). Local certify still passes, so it
            # only surfaces at phase-60 check 4.
            "env": {"ANTHROPIC_API_KEY_URI":
                    "secret://coworld/lux-ai/anthropic_api_key"},
            "source_url": SOURCE_URL,
        },
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "config_schema": CONFIG_SCHEMA,
        "results_schema": RESULTS_SCHEMA,
        "protocols": {"player": text(PLAYER_PROTOCOL),
                      "global": text(GLOBAL_PROTOCOL)},
        "docs": {
            "readme": text(read("README.md")),
            "pages": [
                {"id": "rules.md", "title": "Rules",
                 "content": text(read("docs", "RULES.md"))},
                {"id": "protocol.md", "title": "Wire protocol",
                 "content": text(read("docs", "PROTOCOL.md"))},
                {"id": "commanding.md", "title": "Writing a Lux directive prompt",
                 "content": text(read("docs", "COMMANDING.md"))},
            ],
        },
    }
    manifest["player"] = [
        {"id": "forester", "type": "player", "name": "lux-ai-forester",
         "description":
             "The published scripted default: wood until coal is researched, "
             "expand unless a city is inside sixteen nights of starving. Also "
             "the per-turn LLM fallback and the driver of a no-show seat.",
         "image": "{{LUX_AI_IMAGE}}", "run": ["/bin/lux-ai-player"],
         "source_url": SOURCE_URL,
         "env": {"PLAYER_SCRIPTED": "forester",
                 "PLAYER_POLICY_LABEL": "lux-ai-forester"},
         "resources": PLAYER_RESOURCES},
        {"id": "prospector", "type": "player", "name": "lux-ai-prospector",
         "description":
             "The control: it buys the fuel ladder early and pays for it in "
             "city tiles. Deliberately a different SHAPE from forester so the "
             "ladder gets a spread rather than two versions of one bot.",
         "image": "{{LUX_AI_IMAGE}}", "run": ["/bin/lux-ai-player"],
         "source_url": SOURCE_URL,
         "env": {"PLAYER_SCRIPTED": "prospector",
                 "PLAYER_POLICY_LABEL": "lux-ai-prospector"},
         "resources": PLAYER_RESOURCES},
    ]
    manifest["variants"] = [
        variant("duel", "Lux duel (16x16, 360 turns)",
                "Lux AI Season 1 on a seeded, mirror-symmetric 16x16 island: "
                "nine day/night cycles, wood-coal-uranium, research gates at 50 "
                "and 200, most city tiles standing at turn 360 wins."),
        variant("skirmish", "Skirmish (12x12, 200 turns)",
                "A tighter island and five cycles instead of nine: less room to "
                "expand, and every research point costs a worker you badly "
                "need.",
                mapSize=12, woodClusters=3, coalClusters=1, uraniumClusters=1,
                maxTurns=200),
        variant("scarcity", "Scarcity (16x16, thin wood, rich rock)",
                "Half the wood, more coal and twice the uranium: the wood runs "
                "out around turn 200, so a side that never bought the research "
                "ladder loses its cities in the sixth night.",
                woodClusters=2, coalClusters=3, uraniumClusters=2,
                woodStart=200),
    ]
    cert = dict(BASE)
    # Both seats scripted, no LLM, no rate floor: 360 turns of integer play is
    # ~2 s of wall clock, while the replay is ~408 ticks => ~27 s of playback at
    # 15 turns a second, deliberately longer than any viewer soak window (the
    # ecos 2026-08-23 scar). Seed 42 is chosen because forester vs prospector
    # runs the FULL 360 turns there and crosses a research threshold and nine
    # nightfalls, so the fixture's replay exercises every beat kind.
    cert.update({"turnSpacingMs": 0, "wallClockBudgetSeconds": 240,
                 "lobbyJoinTimeoutTicks": 600, "seed": 42})
    manifest["certification"] = {
        "players": [{"player_id": "forester"}, {"player_id": "prospector"}],
        "game_config": cert,
    }
    out = os.path.join(ROOT, "coworld_manifest_template.json")
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(manifest, indent=2) + "\n")
    print("wrote", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
