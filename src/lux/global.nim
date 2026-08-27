## The board renderer: pixie bakes the island once at load, and every frame
## emits sprite-protocol object updates plus the broadcast chrome JSON.
## Forked from coworld-ctf's `src/ctf/global.nim`, reduced to what Lux needs.
##
## REAL ART, from the starter's shipped assets — no placeholders, no
## solid-colour squares, no downloads. The floor is `data/arena_floor.png`,
## tiled and darkened 18 % with a chalk grid, baked once at reset (the path the
## starter uses for endzone paint). Resource chips and city buildings are baked
## from `data/rock_tile.png` and `data/wall_tile.png` (crops of the starter's
## `client/art/walls/wall_{h,v}.jpg`) tinted through `data/pallete.png`. Units
## are the four nano-banana Softmax-cog renders in `data/cogs/` — one kit per
## role per side, so a worker (tall, axe raised) and a cart (squat, loaded
## wagon) read apart at board scale with no label at all.
##
## The BOARD is one blit plus a bounded number of chips: only the amount
## overlays and the mutable layers (city tiles, units, roads) are drawn per
## frame, and the night wash is the page's own `#lightpool`.

import std/[math, os, strutils, tables]


import bitworld/spriteprotocol
import pixie

import sim

const
  MapLayerId* = SpriteLayerMap
  BoardSpriteId* = 1
  RoadSpriteBase* = 40           ## + level 1..6
  ResourceSpriteBase* = 10       ## + kindIndex * 5 + fullness 0..4
  CitySpriteBase* = 60           ## + seat * 10 + ringLevel 0..8
  UnitSpriteBase* = 100          ## + seat * 4 + kind * 2 + laden
  BoardObjectId* = 1
  RoadObjectBase* = 2000
  ResourceObjectBase* = 6000
  CityObjectBase* = 10000
  UnitObjectBase* = 20000

type
  GlobalViewerState* = object
    initialized*: bool
    spriteDefs*: seq[int]
    objects*: Table[int, array[4, int]]   ## objectId -> [x, y, z, spriteId]
    replayCommands*: seq[char]
    replaySeekTick*: int
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool
    clickPending*: bool
    momentumSent*: bool
    boardSize*: int

proc initGlobalViewerState*(): GlobalViewerState =
  GlobalViewerState(
    objects: initTable[int, array[4, int]](),
    replaySeekTick: -1,
    mouseLayer: MapLayerId)

# ---------------------------------------------------------------------------
#  The bake
# ---------------------------------------------------------------------------

var
  bakedSize = -1
  boardImage: Image
  resourceChips: array[3, array[5, Image]]
  roadChips: array[7, Image]
  cityChips: array[2, array[9, Image]]
  unitChips: array[8, Image]
  palette: array[16, ColorRGBA]

proc assetPath(name: string): string =
  ## `data/` is preloaded into the wasm filesystem at the same relative path
  ## the native binary reads it from, so one lookup serves both.
  ##
  ## NEVER `getAppDir()`. Under emscripten there is no /proc, so Nim's
  ## `getApplAux` gets -1 out of `readlink("/proc/self/exe")` and hands it
  ## straight to `setLen`, which is a RangeDefect on a 32-bit target
  ## ("value out of range: -1 notin 0 .. 2147483647"). It killed the bundle on
  ## its first drawn frame with no other diagnostic, and it is invisible to
  ## every native build because /proc/self/exe resolves there.
  for candidate in [name, "/" & name, "/workspace/lux" / name]:
    if fileExists(candidate):
      return candidate
  name

proc loadPaletteOnce() =
  if palette[1].a != 0:
    return
  let image = readImage(assetPath("data/pallete.png"))
  for i in 0 ..< 16:
    palette[i] = image[min(i, image.width - 1), 0].rgba()

func mix(a, b: ColorRGBA, t: float32): ColorRGBA =
  ColorRGBA(
    r: uint8(clamp(float32(a.r) * (1 - t) + float32(b.r) * t, 0, 255)),
    g: uint8(clamp(float32(a.g) * (1 - t) + float32(b.g) * t, 0, 255)),
    b: uint8(clamp(float32(a.b) * (1 - t) + float32(b.b) * t, 0, 255)),
    a: uint8(clamp(float32(a.a) * (1 - t) + float32(b.a) * t, 0, 255)))

proc tintedTile(source: Image, tint: ColorRGBA, strength: float32): Image =
  result = newImage(source.width, source.height)
  for y in 0 ..< source.height:
    for x in 0 ..< source.width:
      let pixel = source[x, y].rgba()
      result[x, y] = mix(pixel, tint, strength).rgbx()

proc bakeBoard(size: int): Image =
  ## The tiled floor, darkened 18 %, with a 1 px chalk grid — one blit for the
  ## whole island.
  let
    edge = size * CellPixels
    floor = readImage(assetPath("data/arena_floor.png"))
  result = newImage(edge, edge)
  for y in 0 ..< edge:
    for x in 0 ..< edge:
      let pixel = floor[x mod floor.width, y mod floor.height].rgba()
      result[x, y] = ColorRGBA(
        r: uint8(float32(pixel.r) * 0.82),
        g: uint8(float32(pixel.g) * 0.82),
        b: uint8(float32(pixel.b) * 0.86),
        a: 255).rgbx()
  let chalk = ColorRGBA(r: 226, g: 216, b: 196, a: 46)
  for i in 0 .. size:
    let at = min(edge - 1, i * CellPixels)
    for p in 0 ..< edge:
      result[at, p] = mix(result[at, p].rgba(), chalk, 0.35'f32).rgbx()
      result[p, at] = mix(result[p, at].rgba(), chalk, 0.35'f32).rgbx()

proc roundedChip(
  size: int, fill, rim: ColorRGBA, inset: int, radius: float32
): Image =
  result = newImage(size, size)
  let
    half = float32(size) / 2
    outer = half - float32(inset)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        dx = abs(float32(x) + 0.5'f32 - half)
        dy = abs(float32(y) + 0.5'f32 - half)
        qx = max(0'f32, dx - (outer - radius))
        qy = max(0'f32, dy - (outer - radius))
        distance = sqrt(qx * qx + qy * qy) - radius
      if dx > outer or dy > outer or distance > 0.9'f32:
        continue
      result[x, y] = (if distance > -1.6'f32: rim else: fill).rgbx()

proc textured(base: Image, tile: Image, strength: float32): Image =
  result = newImage(base.width, base.height)
  for y in 0 ..< base.height:
    for x in 0 ..< base.width:
      var pixel = base[x, y].rgba()
      if pixel.a == 0:
        continue
      let grain = tile[x mod tile.width, y mod tile.height].rgba()
      pixel = mix(pixel, ColorRGBA(r: grain.r, g: grain.g, b: grain.b,
        a: pixel.a), strength)
      result[x, y] = pixel.rgbx()

proc bakeResourceChips() =
  let rock = readImage(assetPath("data/rock_tile.png"))
  let tints = [
    ColorRGBA(r: 62, g: 138, b: 70, a: 255),      ## wood: green canopy
    ColorRGBA(r: 44, g: 44, b: 52, a: 255),       ## coal: dark faceted chip
    ColorRGBA(r: 214, g: 226, b: 208, a: 255)]    ## uranium: pale, glowing
  let rims = [
    ColorRGBA(r: 32, g: 84, b: 44, a: 255),
    ColorRGBA(r: 16, g: 16, b: 22, a: 255),
    ColorRGBA(r: 120, g: 226, b: 150, a: 255)]
  for kind in 0 .. 2:
    for level in 0 .. 4:
      ## The chip SHRINKS with the remaining amount, so a spectator can see a
      ## belt being mined out; a depleted tile keeps a stump.
      let inset = 3 + (4 - level) * 3
      var chip = roundedChip(CellPixels, tints[kind], rims[kind], inset, 4.0'f32)
      chip = textured(chip, rock, 0.28'f32)
      if kind == 2 and level > 0:
        ## uranium's glow ring
        let glow = ColorRGBA(r: 150, g: 255, b: 190, a: 90)
        let ring = roundedChip(CellPixels, ColorRGBA(a: 0), glow,
          max(1, inset - 2), 5.0'f32)
        for y in 0 ..< CellPixels:
          for x in 0 ..< CellPixels:
            if chip[x, y].rgba().a == 0 and ring[x, y].rgba().a != 0:
              chip[x, y] = ring[x, y]
      resourceChips[kind][level] = chip

proc bakeRoadChips() =
  for level in 1 .. 6:
    let width = 4 + level * 2
    var chip = newImage(CellPixels, CellPixels)
    let
      lo = (CellPixels - width) div 2
      hi = lo + width
      paving = ColorRGBA(r: 196, g: 184, b: 158, a: uint8(60 + level * 18))
    for y in 0 ..< CellPixels:
      for x in 0 ..< CellPixels:
        if (y >= lo and y < hi) or (x >= lo and x < hi):
          chip[x, y] = paving.rgbx()
    roadChips[level] = chip

proc bakeCityChips() =
  let wall = readImage(assetPath("data/wall_tile.png"))
  let bodies = [
    ColorRGBA(r: 200, g: 82, b: 58, a: 255),
    ColorRGBA(r: 63, g: 124, b: 196, a: 255)]
  let rims = [
    ColorRGBA(r: 116, g: 40, b: 28, a: 255),
    ColorRGBA(r: 28, g: 62, b: 116, a: 255)]
  for seat in 0 .. 1:
    for ring in 0 .. 8:
      var chip = roundedChip(CellPixels, bodies[seat], rims[seat], 2, 3.0'f32)
      chip = textured(chip, wall, 0.22'f32)
      ## The roof glyph: a bright notch so a tile reads as a BUILDING and not
      ## as a coloured square.
      let roof = mix(bodies[seat], ColorRGBA(r: 250, g: 240, b: 220, a: 255),
        0.45'f32)
      for y in 6 .. 10:
        for x in 7 ..< CellPixels - 7:
          chip[x, y] = roof.rgbx()
      ## The FUEL RING around the rim: fill = min(1, fuel / (10 * upkeep)), so a
      ## city that cannot survive tonight has a visibly empty ring.
      let
        lit = ColorRGBA(r: 255, g: 208, b: 96, a: 255)
        dark = ColorRGBA(r: 46, g: 40, b: 34, a: 200)
        perimeter = 4 * (CellPixels - 4)
        filled = perimeter * ring div 8
      var index = 0
      for x in 2 ..< CellPixels - 2:
        chip[x, 2] = (if index < filled: lit else: dark).rgbx(); inc index
      for y in 2 ..< CellPixels - 2:
        chip[CellPixels - 3, y] = (if index < filled: lit else: dark).rgbx(); inc index
      for x in countdown(CellPixels - 3, 2):
        chip[x, CellPixels - 3] = (if index < filled: lit else: dark).rgbx(); inc index
      for y in countdown(CellPixels - 3, 2):
        chip[2, y] = (if index < filled: lit else: dark).rgbx(); inc index
      cityChips[seat][ring] = chip

proc bakeUnitChips() =
  ## The four nano-banana cog renders, scaled to the board chip size, with a
  ## 3-segment cargo pip strip along the bottom. Drawing sixty units a frame is
  ## sixty blits.
  const Names = ["red_worker", "red_cart", "blue_worker", "blue_cart"]
  for seat in 0 .. 1:
    for kind in 0 .. 1:
      let source = readImage(assetPath(
        "data/cogs/" & Names[seat * 2 + kind] & ".png"))
      for laden in 0 .. 1:
        var chip = newImage(CellPixels, CellPixels)
        let scaled = source.resize(CellPixels - 2, CellPixels - 2)
        for y in 0 ..< scaled.height:
          for x in 0 ..< scaled.width:
            let pixel = scaled[x, y].rgba()
            if pixel.a > 8:
              chip[x + 1, y + 1] = pixel.rgbx()
        if laden == 1:
          let pip = ColorRGBA(r: 255, g: 208, b: 96, a: 255)
          for segment in 0 .. 2:
            for x in 0 .. 4:
              for y in 0 .. 2:
                chip[3 + segment * 6 + x, CellPixels - 4 + y] = pip.rgbx()
        unitChips[seat * 4 + kind * 2 + laden] = chip

proc ensureBaked(size: int) =
  if bakedSize == size:
    return
  loadPaletteOnce()
  boardImage = bakeBoard(size)
  if bakedSize < 0:
    bakeResourceChips()
    bakeRoadChips()
    bakeCityChips()
    bakeUnitChips()
  bakedSize = size

func rgbaBytes(image: Image): seq[uint8] =
  result = newSeq[uint8](image.width * image.height * 4)
  var at = 0
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let pixel = image[x, y].rgba()
      result[at] = pixel.r
      result[at + 1] = pixel.g
      result[at + 2] = pixel.b
      result[at + 3] = pixel.a
      at += 4

# ---------------------------------------------------------------------------
#  Client messages
# ---------------------------------------------------------------------------

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Transport commands and board clicks arrive as sprite-protocol client
  ## messages. `s:<tick>` is a scrubber seek; every other printable command is
  ## a single transport key the replay player understands.
  for item in parseSpriteClientMessages(message):
    case item.kind
    of SpriteClientChatMessage:
      let text = item.text.strip()
      if text.startsWith("s:"):
        try:
          state.replaySeekTick = parseInt(text[2 .. ^1])
        except CatchableError:
          discard
      else:
        for ch in text:
          state.replayCommands.add(ch)
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      if item.hasLayer:
        state.mouseLayer = item.layer
    of SpriteClientMouseButtonMessage:
      state.mouseDown = item.down
      if item.down:
        state.clickPending = true
    else:
      discard

# ---------------------------------------------------------------------------
#  The packet
# ---------------------------------------------------------------------------

proc addSpriteOnce(
  packet: var seq[uint8], state: var GlobalViewerState,
  spriteId: int, image: Image, label: string
) =
  if spriteId in state.spriteDefs:
    return
  state.spriteDefs.add(spriteId)
  packet.addSprite(spriteId, image.width, image.height,
    image.rgbaBytes(), label)

proc place(
  packet: var seq[uint8], state: var GlobalViewerState,
  objectId, x, y, z, spriteId: int, live: var seq[int]
) =
  live.add(objectId)
  let wanted = [x, y, z, spriteId]
  if state.objects.getOrDefault(objectId, [-1, -1, -1, -1]) == wanted:
    return
  state.objects[objectId] = wanted
  packet.addObject(objectId, x, y, z, MapLayerId, spriteId)

func fullnessLevel(amount, start: int): int =
  if amount <= 0: 0
  else: clamp(1 + (amount * 4) div max(1, start * 2), 1, 4)

func ringLevel(fuel: int64, upkeep: int): int =
  if upkeep <= 0: 8
  else: int(clamp(fuel * 8'i64 div int64(10 * upkeep), 0'i64, 8'i64))

proc ensureBoardArt*(size: int) =
  ## Bakes the island and every chip for one board size. Exposed so the wasm
  ## entry can stamp its own progress note around it: the bake reads five PNGs
  ## out of the preloaded filesystem and is the first thing that can fail on a
  ## page that has otherwise loaded.
  ensureBaked(size)

proc buildBoardPacket*(
  sim: var SimServer, state: GlobalViewerState, nextState: var GlobalViewerState
): seq[uint8] =
  ## Every frame's board update: the baked island once, then only the objects
  ## whose position or sprite changed, plus a delete for anything that is gone.
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  nextState.clickPending = false
  let
    world = sim.world
    size = world.board.size
    edge = size * CellPixels
  ensureBaked(size)
  if not nextState.initialized or nextState.boardSize != size:
    nextState.initialized = true
    nextState.boardSize = size
    nextState.spriteDefs.setLen(0)
    nextState.objects.clear()
    result.addLayer(MapLayerId, 0, SpriteLayerZoomableFlag)
    result.addViewport(MapLayerId, edge, edge)
    result.addClearObjects()
  result.addSpriteOnce(nextState, BoardSpriteId, boardImage, "island")
  var live: seq[int] = @[BoardObjectId]
  if not state.objects.hasKey(BoardObjectId):
    nextState.objects[BoardObjectId] = [0, 0, 0, BoardSpriteId]
    result.addObject(BoardObjectId, 0, 0, 0, MapLayerId, BoardSpriteId)

  for cell in 0 ..< world.board.cellCount():
    let
      x = world.board.cellX(cell) * CellPixels
      y = world.board.cellY(cell) * CellPixels
    if world.board.road[cell] > 0:
      let level = min(6, world.board.road[cell])
      let spriteId = RoadSpriteBase + level
      result.addSpriteOnce(nextState, spriteId, roadChips[level], "road")
      result.place(nextState, RoadObjectBase + cell, x, y, 1, spriteId, live)
    let kind = world.board.terrain[cell]
    if kind != tEmpty:
      let
        start = startAmount(kind, sim.config.woodStart, sim.config.coalStart,
          sim.config.uraniumStart)
        level = fullnessLevel(world.board.amount[cell], start)
        index = ord(kind) - 1
        spriteId = ResourceSpriteBase + index * 5 + level
      result.addSpriteOnce(nextState, spriteId, resourceChips[index][level],
        $kind)
      result.place(nextState, ResourceObjectBase + cell, x, y, 2, spriteId, live)
    if world.cities.hasTile(cell):
      let
        seat = world.cities.teamOfCell[cell]
        cityIndex = world.cities.indexOfCity(world.cities.cityOfCell[cell])
      var ring = 8
      if cityIndex >= 0:
        let city = world.cities.list[cityIndex]
        ring = ringLevel(city.fuel, city.upkeep(world.board,
          sim.config.cityUpkeepPerTile, sim.config.cityAdjacencyDiscount))
      let spriteId = CitySpriteBase + seat * 10 + ring
      result.addSpriteOnce(nextState, spriteId, cityChips[seat][ring], "city")
      result.place(nextState, CityObjectBase + cell, x, y, 3, spriteId, live)

  for unit in world.units.list:
    let
      seat = ord(unit.team)
      kind = ord(unit.kind)
      laden = if unit.totalCargo() > 0: 1 else: 0
      spriteId = UnitSpriteBase + seat * 4 + kind * 2 + laden
      x = world.board.cellX(unit.cell) * CellPixels
      y = world.board.cellY(unit.cell) * CellPixels
    result.addSpriteOnce(nextState, spriteId,
      unitChips[seat * 4 + kind * 2 + laden], $unit.kind)
    result.place(nextState, UnitObjectBase + unit.id, x, y, 4, spriteId, live)

  var gone: seq[int] = @[]
  for objectId in nextState.objects.keys:
    if objectId notin live:
      gone.add(objectId)
  for objectId in gone:
    nextState.objects.del(objectId)
    result.addDeleteObject(objectId)

proc addChrome*(packet: var seq[uint8], stateJson: string) =
  ## The chrome JSON rides the LABEL of a reserved sprite id — the only channel
  ## the binary stream has for text, and the one the inherited
  ## `broadcast_core.js` already routes to `onText`.
  packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], stateJson)

proc boardPreview*(): Image =
  ## Test-only: the baked island, for `tools/` previews and the viewer tests.
  boardImage

proc spritePreview*(spriteId: int): Image =
  ## Test-only: the baked chip behind one sprite id.
  if spriteId >= UnitSpriteBase and spriteId < UnitSpriteBase + 8:
    return unitChips[spriteId - UnitSpriteBase]
  if spriteId >= CitySpriteBase and spriteId < CitySpriteBase + 20:
    let index = spriteId - CitySpriteBase
    return cityChips[index div 10][index mod 10]
  if spriteId >= RoadSpriteBase and spriteId <= RoadSpriteBase + 6:
    return roadChips[spriteId - RoadSpriteBase]
  if spriteId >= ResourceSpriteBase and spriteId < ResourceSpriteBase + 15:
    let index = spriteId - ResourceSpriteBase
    return resourceChips[index div 5][index mod 5]
  nil
