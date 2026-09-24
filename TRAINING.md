# Lux AI post-training

`tools/export_posttrain.nim` plays ten complete native games per certified
variant. At each directive turn it captures the exact hosted system prompt
and fully observable seat view. The shipped forester and prospector policies
supply replies accepted by the production parser. Both seats choose from
the same pre-turn state, then the native simulator advances. Whole games
stay in one data split.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/lux-posttrain tools/export_posttrain.nim
python3 tools/test_posttrain.py /tmp/lux-posttrain
/tmp/lux-posttrain /tmp/lux-data 10 duel
```

The other certified variants are `skirmish` and `scarcity`. Ten games yielded
560 train and 144 validation decisions for `duel`, 304 and 80 for
`skirmish`, and 488 and 64 for `scarcity`. The largest examples used 1,927,
1,829, and 1,866 tokens with a local Qwen2.5 tokenizer, all within 4,096.
One CPU optimizer step on a tiny local model reduced validation loss from
5.5577 to 5.4806, 5.4780 to 5.4029, and 5.4845 to 5.4004, respectively.
These short runs verify the training path, not policy quality.

From a Metta checkout with `metta-posttrain` installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/lux-data --output /tmp/lux-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

The `scarcity` variant starts wood at 200 units. Wood can regrow to 500, so
the simulator guard now accepts that legal amount. The change is recorded as
GameVersion 2.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes 2,064 values from the public board, units,
resources, and standings. Ten action heads cover every structured field of
the native directive. Both seats choose against one pre-turn state, then the
production simulator executes the directives until the next decision.

```sh
nim c -d:release --path:src -o:/tmp/lux-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/lux-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute bridge
and manifest paths to `recipes.external.coworld.train` for native PufferLib,
or `recipes.external.coworld_metta_rl.train` for Metta RL. Use `players=2`,
`max_decisions=72`, a timestep limit, and one of the three variant IDs.
The bridge also publishes the hosted observation as `semantic_view` and
`messages`.
