## Release-only: a full two-sided 360-turn episode, both micros, bounded.
## Listed in NIM_TESTS_RELEASE_ONLY — a debug build is 10-50x slower and the
## bound would say nothing.

import std/[times, unittest]

import lux/sim
import helpers

suite "lux perf":
  test "360 turns of both sides' micro plus resolution finish well inside 60 s":
    let started = epochTime()
    let game = scriptedEpisode(fixtureConfig(seed = 1734029581))
    let elapsed = epochTime() - started
    checkpoint("elapsed " & $elapsed & " s for " & $game.tickCount & " ticks")
    check game.world.turn > 300
    check elapsed < 60.0

  test "the whole-episode pre-scan the viewer runs at load is cheap too":
    ## `initReplayPlayer` re-simulates the episode once headlessly; the load
    ## screen only exists for as long as this takes.
    let started = epochTime()
    for _ in 0 ..< 3:
      discard scriptedEpisode(fixtureConfig(seed = 42))
    let elapsed = (epochTime() - started) / 3.0
    checkpoint("one headless episode: " & $elapsed & " s")
    check elapsed < 20.0
