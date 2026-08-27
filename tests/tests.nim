## Every test, in one binary. `nim r --path:src tests/tests.nim` from the repo
## ROOT (assets resolve via `data/`). `ci.yml` runs each file individually, in
## debug AND release; the four shards below are the balanced split.
import
  test_lux_board, test_lux_resolve, test_lux_scoring, test_lux_endings,
  test_lux_determinism, test_lux_baselines, test_lux_micro,
  test_lux_directives, test_lux_observation, test_lux_identity_privacy,
  test_lux_engine, test_lux_replay, test_lux_manifest, test_lux_viewer,
  test_lux_endcard_labels, test_lux_label_contract, test_lux_gameversion,
  test_lux_scaffold
