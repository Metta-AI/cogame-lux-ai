# Agent operating guide — cogame-lux-ai

Orientation for coding agents. Gameplay rules live in [docs/RULES.md](docs/RULES.md),
the wire protocol in [docs/PROTOCOL.md](docs/PROTOCOL.md), and the full design
note (the specification this repo was built from) in
[docs/plans/2026-08-27-lux-ai-design.md](docs/plans/2026-08-27-lux-ai-design.md).

## The three things that are easy to get wrong

### 1. `GameVersion` gates replay compatibility

`src/lux/sim_types.nim` carries `GameVersion` with a **prepend-only** changelog
comment in the shape `GVnn (short rule name): HEADLINE`. Bump it in the same
commit as ANY change to the rules, the hash mix order or the replay record
vocabulary, and say what the number means and what it obsoletes. Check with:

```bash
tools/ci/check_gameversion.sh origin/main
```

CI runs the same check on every PR (the `gameversion` job in
[.github/workflows/ci.yml](.github/workflows/ci.yml)), against the branch the PR
merges into.

Know what it does NOT cover. It catches one thing: two branches spending the
same number on different rules. It cannot see that a rules change forgot to
bump at all — nothing in the build ties a gameplay diff to a version bump — and
it reads "behind" off the digits alone, so a branch that jumps a number is
exempt from the check and spends that number permanently.

The number alone cannot detect a collision between two branches — what
distinguishes them is the RULE the number is attached to, which is why the
script diffs the changelog headline and not the digits.

### 2. The hash mix order IS the format

`sim_state.gameHash` mixes a fixed sequence. Add a field only at the END, and
bump `GameVersion`. The browser re-simulates the same Nim modules and compares
its own hash against the recorded one every tick, so a reordered mix turns
every existing replay into a hash warning.

Nothing a commander **says** may move the chain: the note, the source, the
latency and every policy label are excluded on purpose.

### 3. The chrome is inherited, not written

- `client/chrome_common.js` and `client/broadcast_core.js` are **byte-identical**
  to coworld-ctf's and are pinned by sha256 in `tests/test_lux_viewer.nim`. Do
  not edit them. Anything lux-ai needs lives in the appended game block.
- `client/replay_broadcast.html` is coworld-ctf's page with exactly the
  deletions the design note names plus one appended block.
  **Regenerate it, do not hand-edit it:**

  ```bash
  python3 scripts/fork_broadcast_page.py /path/to/coworld-ctf \
      client/replay_broadcast.html
  ```

  The game block itself lives in `scripts/lux_block.html`.
- Every game-block identifier carries a `lux` prefix because the page's chrome
  alias block declares its names with a hoisted `var`; a same-named function in
  the game block is silently swallowed and the scrubber ends up with unlabelled
  markers that never seek. `tests/test_lux_viewer.nim` asserts the whole alias
  list is untouched below the banner.

## Layout

- `src/lux_ai.nim` — the game entrypoint. **Seed randomisation happens HERE**,
  before `config.update`, so every seed-derived draw follows the final seed.
- `src/lux_ai_player.nim` — the thin seat registrar. It makes no LLM call.
- `src/lux/`:
  - `sim_types` consts and enums (incl. `GameVersion` and every rune cap);
    `sim_config` the `GameConfig` lifecycle and `validate`;
    `sim_state` the `World`, the hash chain, the sim guard and the events.
  - `board` `units` `cities` `resolve` `scoring` — the rules, **pure integer**.
    A CI grep over exactly those files (plus `sim`, `micro`, `baselines`)
    forbids floating point; the one documented float in the whole sim is
    `scoring.scoreOf`, the serialisation boundary.
  - `directives` the reply schema and the tolerant parser; `micro` the
    directive → actions compiler; `baselines` the two fillers.
  - `llm` the transport; `decide` the one-parallel-batch turn loop.
  - `replays` `replay_runtime` `broadcast` `global` `roster` `wire_constants`
    `server`.
  - `sim` imports and RE-EXPORTS the sim modules, so `import lux/sim` sees
    everything. **It never reaches the network** — the same file compiles to
    wasm for the viewer.
- `tests/` — run from the repo **ROOT** (assets resolve via `data/`).
  `ci.yml` runs every file twice, debug and release.

## Regenerating the generated files

```bash
python3 scripts/build_manifest.py                     # coworld_manifest_template.json
python3 scripts/fork_broadcast_page.py <ctf> client/replay_broadcast.html
python3 scripts/art/split_cog_sheet.py                # data/cogs/*.png
nim r -d:release --path:src tools/tune_baselines.nim --write   # baseline_tuning.json
```

Each has a committed output and a test that fails if the two drift.

## Two amendments to the design note's rule order

Both are in `docs/RULES.md` with their reasons: **production before research**
in the city-tile rules, and **`prospector` carries `forester`'s night guard and
plants a seed blob first**. Read them before touching `micro.nim` or
`baselines.nim` — the literal reading of the note produces a game where nothing
is ever built.

## Debugging a hosted replay

The replay is `COWLDLUX` binary. Do not open the Observatory UI:

```bash
curl -sSL "https://softmax-public.s3.amazonaws.com/replays/<uuid>.replay" -o /tmp/ep.replay
python3 tools/replay_summary.py /tmp/ep.replay | jq .
```

`parseLuxReplay` + `initReplayRuntime` replays it locally, exactly like the
wasm viewer, and `tools/wasm_replay_smoke.cjs` runs the EXACT emitted wasm
module under headless node.

## Disposable QA Storage

This guidance applies only to this repository's first-party diagnostics, not
vendored/third-party code or other repositories.

- Default disposable diagnostic/audit logs, screenshots, frame dumps and
  browser reports to the OS temporary directory in an application-specific,
  unique per-run subdirectory, such as `cogame-lux-ai-qa-<unique-run-id>`.
  Use platform temporary-directory APIs or `mktemp -d`, and existing helpers
  where available; do not reuse a fixed shared QA directory.
- Respect explicit output paths, artifact URIs and intentional retention.
  Preserve retained replays, evidence, saves, checkpoints, and research
  inputs/outputs, including game trajectory/proof records. Do not silently
  classify them as disposable or move them to temporary storage.
- Bound capture duration, frame/file count and supported byte limits; check
  free space on the destination filesystem before large captures and report
  the actual artifact path. Stop or skip if space is insufficient.
- Temporary storage may share the checkout's disk and is not guaranteed to
  clear on reboot. It does not reduce live disk consumption.
- Keep live IPC/control sockets, status pointers, leases and databases at
  their required fixed locations so consumers remain compatible.
- Codex/Claude sessions, prompts, traces, histories, recovery exports, indexes
  and databases are protected archival data, never disposable game QA output.
  NEVER delete, prune, rotate, truncate, rewrite or move any of them. Do not
  redirect coding-agent storage to temporary directories.
- This policy does not authorize cleanup. Leave existing artifacts, other
  tasks' outputs untouched.
- For AGENTS.md-only changes, use documentation checks (`git diff --check`
  and diff review); do not run game builds, dependency sync or populate global
  build/dependency caches.
- Repository-specific diagnostic reference:
  `tools/ci/viewer_smoke.mjs` supports `--out`, `--timeout`
  and `--soak` and emits `viewer-smoke.png` / `viewer-smoke.json`. For
  disposable local QA, pass a unique temporary directory via `--out`; keep
  explicit retained replay/evidence paths unchanged.
