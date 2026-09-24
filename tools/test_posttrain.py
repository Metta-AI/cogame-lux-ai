"""Check complete, seed-separated Lux AI post-training games."""

import json
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


for variant in ("duel", "skirmish", "scarcity"):
    with TemporaryDirectory() as temporary:
        output = Path(temporary) / variant
        subprocess.run([sys.argv[1], str(output), "10", variant], check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        assert len(manifest["runs"]) == 10
        assert manifest["train_examples"] == len(train) > 0
        assert manifest["validation_examples"] == len(validation) > 0
        assert {row["seed"] for row in train}.isdisjoint({row["seed"] for row in validation})
        assert all(run["reason"] == "complete" and sum(run["scores"]) == 1 for run in manifest["runs"])
        for row in train + validation:
            assert row["game"] == "lux-ai"
            assert [part["role"] for part in row["prompt"]] == ["system", "user"]
            observation = json.loads(row["prompt"][1]["content"])
            assert "map" in observation and "yours" in observation and "theirs" in observation
            directive = json.loads(row["completion"][0]["content"])
            assert set(directive) == {
                "stance", "mine", "research", "build", "workers", "carts", "night", "focus"
            }
            assert len(directive["mine"]) == 3
        print(f"{variant}: {len(train)} train, {len(validation)} validation decisions")
