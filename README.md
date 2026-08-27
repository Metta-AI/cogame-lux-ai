# cogame-lux-ai

**A two-seat, zero-sum economy RTS at board-game tempo** — a port of the
[Lux AI Challenge Season 1](https://github.com/Lux-AI-Challenge/Lux-Design-S1)
rules onto a 16 × 16 mirrored island.

Two sides gather wood, coal and uranium, spend research to unlock the better
fuels, grow cities out of city tiles, and **every ten turns the sun goes down
and each city must pay its light bill or die on the spot**. Most city tiles
standing at turn 360 wins.

A policy is just a prompt. Every ten turns the game server asks each side's
model for **one strategy object** — a stance, a mining priority, a research
target, what city tiles should build, worker and cart targets, a focus cell and
a night policy — and a deterministic controller executes it for the next ten
turns, moving every unit and telling every tile what to do. The model plays the
layer that decides games; the controller plays the layer that code does better.

- The board is a **fixed 16 × 16 grid** and the whole island is always in frame.
- The map is **generated from the episode seed and perfectly mirror-symmetric**,
  so neither side can be dealt a better island.
- The game is **fully observable**: both sides see the entire board, both
  research counts and every resource amount. What is hidden is the opponent's
  *plan*, never the board.
- `scores[0] + scores[1] == 1.0` on **every** episode — a strict zero-sum duel.

Read the rules in [`docs/RULES.md`](docs/RULES.md), the wire protocol in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md), and how to write a prompt that plays
well in [`docs/COMMANDING.md`](docs/COMMANDING.md). The full design note is
[`docs/plans/2026-08-27-lux-ai-design.md`](docs/plans/2026-08-27-lux-ai-design.md).

## Policies

One image, two entrypoints, four policies switched entirely by environment:

| policy | env | what it is |
|---|---|---|
| `lux-ai-lumberjack` | `PLAYER_PROMPT=…` | champion #1 — wood first, cities second, research only when the wood tells you to |
| `lux-ai-nightwatch` | `PLAYER_PROMPT=…` | champion #2 — win the second half; cheap fuel loses to dense fuel |
| `lux-ai-forester` | `PLAYER_SCRIPTED=forester` | the published scripted default, the per-turn LLM fallback and the certification player |
| `lux-ai-prospector` | `PLAYER_SCRIPTED=prospector` | the control: buys the fuel ladder early and pays for it in tiles |

The two champion prompts are in
[`scripts/champion_prompts.json`](scripts/champion_prompts.json) and in
[`tools/ci/policies.json`](tools/ci/policies.json). **The LLM call is made by the
GAME container**, not by the player pod — that is where the coworld secret is
injected — so no policy needs a Bedrock flag.

## Layout

```
src/lux_ai.nim              the game entrypoint (/bin/lux-ai)
src/lux_ai_player.nim       the thin seat registrar (/bin/lux-ai-player)
src/lux/                    the sim, the decision layer, the server
  board units cities resolve scoring     the rules, pure integer
  micro directives baselines             directive -> actions, the two fillers
  llm decide                             the parallel batch and its fallbacks
  sim sim_state sim_config sim_types     the step loop and the hash chain
  replays replay_runtime broadcast global server wire_constants roster
client/                     the broadcast page (see below)
replay-viewer/              the emscripten wasm entry + the static shell
scripts/                    the art pipeline and the reproducible page fork
tools/                      the build hook, the tuner, the forensics
tests/                      the Nim tests ci.yml runs in debug AND release
```

## The viewer is a static wasm bundle, never a pod

`tools/build_replay_viewer.sh` (the `coworld build` hook) compiles
`replay-viewer/lux_replay.nim` — which imports **the same `src/lux/sim.nim` the
server runs** — to WebAssembly through the pinned `emscripten/emsdk` container,
and bundles it with the broadcast page. In the browser the module re-simulates
every turn from the recorded directives and compares its own `gameHash` against
the recorded one **every tick**; a single divergent bit surfaces as a warning at
the tick it happens.

`client/chrome_common.js` and `client/broadcast_core.js` are **byte-for-byte**
coworld-ctf's. `client/replay_broadcast.html` is coworld-ctf's page with exactly
the deletions the design note names and one appended game block;
`scripts/fork_broadcast_page.py` reproduces that fork from the starter mount, so
the diff is reviewable rather than asserted.

## Art

Board and tile art is baked at load by pixie from the starter's shipped assets
(`data/arena_floor.png` tiled and darkened with a chalk grid, resource chips and
city roofs textured from crops of the starter's wall JPEGs, tinted through
`data/pallete.png`). The **unit sprites are nano-banana renders of the Softmax
cog, one kit per role**: a worker is tall and narrow with a raised axe, a cart is
a squat armless wagon heaped with logs and coal, so the two roles read apart at
board scale with no label at all. The source sheet is
`scripts/art/source/cogs_sheet.png` and the splitter is
`scripts/art/split_cog_sheet.py`; the derived PNGs are committed because CI does
not regenerate art.

## Building and testing

The sandbox that wrote this repo has no Docker, no Nim and no emsdk: **CI is the
harness.** `.github/workflows/ci.yml` runs every `tests/*.nim` twice (debug for
range and overflow checks, release for codegen), builds the production image and
plays one real episode in raw Docker from the certification fixture, then builds
the wasm bundle and opens it in headless chromium against **that episode's own
replay**.

Locally, with a Nim 2.2.4 toolchain and the pinned dependency tree:

```bash
nimby --global sync nimby.lock
nim r --path:src tests/tests.nim
nim c -d:release --out:lux-ai src/lux_ai.nim
```

## Releasing

`.github/workflows/coworld-release.yml` (dispatch only) runs
build → certify → upload-policies → upload-coworld → secret put, in that order,
and writes `release-result.json` as the `release-result` artifact.
`.github/workflows/coworld-submit.yml` submits one policy as one player.
