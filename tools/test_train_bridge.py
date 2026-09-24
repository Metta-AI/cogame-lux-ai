"""Exercise complete Lux AI games through the numeric bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
for variant in ("duel", "skirmish", "scarcity"):
    for policy in ("teacher", "random"):
        with subprocess.Popen(
            [sys.argv[1], str(manifest), variant],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        ) as bridge:
            assert bridge.stdin is not None and bridge.stdout is not None

            def request(payload):
                bridge.stdin.write(json.dumps(payload) + "\n")
                bridge.stdin.flush()
                return json.loads(bridge.stdout.readline())

            observation = request({"kind": "reset", "seed": f"{variant}-{policy}", "players": 2})
            rng = random.Random(42)
            decisions = 0
            while observation["kind"] == "decision":
                view = observation["semantic_view"]
                assert {"terrain", "cities", "units"} <= set(view["map"])
                assert observation["messages"][0]["content"].startswith("You")
                encoded = request({"kind": "encode"})
                assert encoded["decision_id"] == observation["decision_id"]
                assert len(encoded["values"]) == 2064
                assert [len(head["choices"]) for head in encoded["action_heads"]] == [
                    5, 6, 4, 4, 10, 11, 2, view["map"]["size"], view["map"]["size"], 3
                ]
                if policy == "teacher":
                    action = json.loads(request({"kind": "teacher"})["response"])
                else:
                    action = {head["name"]: rng.choice(head["choices"]) for head in encoded["action_heads"]}
                assert all(action[head["name"]] in head["choices"] for head in encoded["action_heads"])
                result = request(
                    {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
                )
                assert result["kind"] == "accepted" and result["action"] == action
                observation = result["observation"]
                decisions += 1
            assert 2 <= decisions <= 72
            assert set(observation["scores"]) == {"0", "1"}
            assert sum(observation["scores"].values()) == 1
            assert all(-1 <= utility <= 1 for utility in observation["utilities"].values())
            bridge.stdin.close()
            assert bridge.wait() == 0
        print(f"{variant} {policy}: {decisions} decisions, 2064 values")
