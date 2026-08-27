## The sprite-label contract: the board stream's label vocabulary is CLOSED and
## equals `tests/label_manifest.txt`.

import std/[algorithm, strutils, unittest]

import bitworld/spriteprotocol
import lux/[broadcast, global, sim]
import helpers

suite "lux label contract":
  test "the emitted sprite labels equal tests/label_manifest.txt":
    var game = initSimServer(fixtureConfig(seed = 42))
    game.seats[0].joined = true
    game.seats[1].joined = true
    var
      viewer = initGlobalViewerState()
      next: GlobalViewerState
      observed: seq[string]
    for turn in 0 ..< 200:
      if game.phase == Playing and game.isDirectiveTurn(game.world.turn):
        game.setDirective(0, scriptedDirective(game.world, blForester, 0))
        game.setDirective(1, scriptedDirective(game.world, blProspector, 1))
      let packet = buildBoardPacket(game, viewer, next)
      viewer = next
      for message in packet.parseSpritePacket():
        if message.kind != spkSprite:
          continue
        if message.sprite.id == BroadcastChromeSpriteId:
          continue                          ## the chrome JSON, not a label
        let label = message.sprite.label
        if label.len > 0 and label notin observed:
          observed.add(label)
      game.step()
    var expected: seq[string]
    for line in readRepoFile("tests/label_manifest.txt").splitLines():
      let stripped = line.strip()
      if stripped.len > 0 and not stripped.startsWith("#"):
        expected.add(stripped)
    observed.sort()
    expected.sort()
    checkpoint("observed: " & observed.join(" "))
    check observed == expected

  test "the chrome JSON rides sprite 4090 and nothing else":
    var game = initSimServer(fixtureConfig(seed = 42))
    var
      viewer = initGlobalViewerState()
      next: GlobalViewerState
    var packet = buildBoardPacket(game, viewer, next)
    packet.addChrome("{\"t\":0}")
    var chromeSprites = 0
    for message in packet.parseSpritePacket():
      if message.kind == spkSprite and
          message.sprite.id == BroadcastChromeSpriteId:
        inc chromeSprites
        check message.sprite.label == "{\"t\":0}"
    check chromeSprites == 1

  test "the board stream declares one zoomable map layer at the board size":
    var game = initSimServer(fixtureConfig(seed = 42))
    var
      viewer = initGlobalViewerState()
      next: GlobalViewerState
    let packet = buildBoardPacket(game, viewer, next)
    var viewports = packet.spritePacketViewports()
    check viewports.len == 1
    check viewports[0].width == game.world.board.size * CellPixels
    check viewports[0].height == game.world.board.size * CellPixels
