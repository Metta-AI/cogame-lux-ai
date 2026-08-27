## The game entrypoint (`/bin/lux-ai`).
##
## SEED RANDOMISATION HAPPENS HERE, before `config.update`, so every
## seed-derived draw — the whole island — follows the FINAL seed (the starter's
## rule). The resolved seed is recorded in the replay config and in
## `results.seed`.

import std/[json, os, random]

import bitworld/runtime
import lux/[server, sim]

proc main() =
  let runtimeConfig = readRuntimeConfig()
  var config = defaultGameConfig()
  randomize()
  config.seed = rand(1 .. 2_000_000_000)
  if runtimeConfig.config.len > 0:
    config.update(parseJson(runtimeConfig.config))
  config.validate()
  let saveReplay =
    if runtimeConfig.replayUri.len > 0:
      outputPathFromCogameUri(runtimeConfig.replayUri,
        "COGAME_SAVE_REPLAY_URI", "replay.replay")
    else:
      getEnv("LUX_SAVE_REPLAY")
  runServerLoop(
    host = runtimeConfig.host,
    port = runtimeConfig.port,
    initialConfig = config,
    saveReplayPath = saveReplay,
    loadReplayBytes = runtimeConfig.replay,
    runtimeConfig = runtimeConfig)

when isMainModule:
  main()
