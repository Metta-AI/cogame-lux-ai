## Shared constants and wire enums for cogame-lux-ai.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_types.nim`. Everything here is
## either a hard rule constant of Lux AI Season 1 (transcribed to integers —
## see `docs/RULES.md` for the divergences) or a cap on a string that reaches
## the replay.
##
## RUNE DISCIPLINE. Every cap below is measured in RUNES (Unicode codepoints).
## `truncateRunes` in `directives.nim` is the ONLY place a recorded string is
## shortened, and it cuts on a rune boundary. Slicing a string by BYTE index
## anywhere on the path to the replay is forbidden: a byte-truncated multi-byte
## character renders fine in a browser and then fails a strict UTF-8 parser.

const
  GameVersion* = "1"
    ## Replay compatibility gate. PREPEND-ONLY changelog; say what the number
    ## means and what it obsoletes, in the `GVnn (rule): HEADLINE` shape the
    ## starter's `tools/ci/check_gameversion.sh` diffs.
    ##
    ## GV1 (lux season 1): first rules — 16x16 mirrored island, 40-turn
    ## day/night cycle, wood/coal/uranium with research gates at 50 and 200,
    ## city upkeep 23/tile less 5 per touching pair, most city tiles at turn
    ## 360 wins.

  GameName* = "lux-ai"
  ReplayMagic* = "COWLDLUX"
  ReplayFormatVersion* = 1'u16
  ReplayProtocol* = "lux-ai/v1"

  TargetFps* = 24
    ## Lobby / GameOver real-time tick rate. A PLAYING tick is one Lux turn and
    ## is stepped as fast as the engine can (fastMode), so this only paces the
    ## lobby countdown and the post-game hold.
  ReplayFps* = 15
    ## Playback rate: 15 turns per second. A `duel` replay is 48 lobby ticks +
    ## 360 turns + 72 gameOverTicks = 480 ticks => 32 s of playback, which
    ## deliberately outlasts any viewer soak window.
  PlaybackSpeeds*: array[5, int] = [1, 2, 4, 8, 16]
    ## Halves/doubles around index 1 in the chrome's speed chips.

  MaxNoteRunes* = 160
  MaxPolicyLabelRunes* = 64
  MaxFallbackDetailRunes* = 200
  MaxPromptRunes* = 4000
  MaxHowItWentRunes* = 240
  MaxReplyBytes* = 4096
    ## Read from the provider before parsing; anything longer is truncated
    ## (on a rune boundary) and then parsed.
  MaxDirectiveBytes* = 512
    ## The serialised structured directive must fit this; asserted by the
    ## bounded-orders test on both scripted baselines.

  # --- Board -----------------------------------------------------------
  MaxMapSize* = 32
  MaxRoad* = 6

  # --- Cargo, rates, costs (S1) ----------------------------------------
  WorkerCargo* = 100
  CartCargo* = 2000
  CityCost* = 100
  WoodRate* = 20
  CoalRate* = 5
  UraniumRate* = 2
  WoodFuel* = 1
  CoalFuel* = 10
  UraniumFuel* = 40
  CoalResearch* = 50
  UraniumResearch* = 200
  CityUpkeepPerTile* = 23
  CityAdjacencyDiscount* = 5
  WorkerUpkeep* = 4
  CartUpkeep* = 10
  WorkerCooldown* = 20
  CartCooldown* = 30
  CityCooldown* = 100
  WoodRegrowCap* = 500
  BuildRadius* = 6
  MaxCityFuel* = 1'i64 shl 40
    ## The sim guard's ceiling on `city.fuel` (int64; a cart of uranium is
    ## 80 000 fuel and a long game banks six figures).

  # --- Observation caps -------------------------------------------------
  MaxObservedCities* = 8
  MaxObservedCells* = 12
  MaxRichestTiles* = 6

  BroadcastChromeSpriteId* = 4090
    ## Reserved sprite id whose LABEL carries the broadcast chrome JSON on the
    ## binary channel. Kept off the drawable sprite map by the client.
  CellPixels* = 24
    ## Board render scale: one cell is 24x24 px in the sprite stream. A 16x16
    ## island is a 384x384 native board, letterboxed by the viewer at every
    ## width including the 360 px featured-match embed.

type
  LuxError* = object of CatchableError
    ## Any recoverable engine fault.

  LuxGuardError* = object of LuxError
    ## `checkLuxInvariants()` tripped: the episode settles `fault`/`sim_fault`.

  Team* = enum
    Red = 0
    Blue = 1

  Phase* = enum
    Lobby = "lobby"
    Playing = "playing"
    GameOver = "gameover"

  UnitKind* = enum
    ukWorker = "worker"
    ukCart = "cart"

  Terrain* = enum
    tEmpty = "empty"
    tWood = "wood"
    tCoal = "coal"
    tUranium = "uranium"

  Direction* = enum
    dCenter = "center"
    dNorth = "north"
    dEast = "east"
    dSouth = "south"
    dWest = "west"

  EndReason* = enum
    erComplete = "complete"
    erDeadline = "deadline"
    erFault = "fault"

  EndRule* = enum
    erlNone = ""
    erlFullTime = "full_time"
    erlEliminated = "eliminated"
    erlWallClock = "wall_clock"
    erlSimFault = "sim_fault"
    erlHostError = "host_error"

  SimEventKind* = enum
    PhaseChange
    Dawn
    Dusk
    CityBuilt
    CityLost
    UnitBuilt
    UnitLost
    Research
    Depleted
    Directive
    Fallback

  SimEvent* = object
    ## The tier-2 analysis row. Never enters `gameHash`.
    tick*: int
    kind*: SimEventKind
    seat*: int
    cell*: int
    amount*: int
    unitKind*: string
    resource*: string
    cause*: string
    content*: string

func teamText*(team: Team): string =
  if team == Red: "red" else: "blue"

func other*(team: Team): Team =
  if team == Red: Blue else: Red

func fuelValue*(kind: Terrain): int =
  case kind
  of tWood: WoodFuel
  of tCoal: CoalFuel
  of tUranium: UraniumFuel
  of tEmpty: 0

func mineRate*(kind: Terrain): int =
  case kind
  of tWood: WoodRate
  of tCoal: CoalRate
  of tUranium: UraniumRate
  of tEmpty: 0

func researchNeeded*(kind: Terrain): int =
  case kind
  of tWood: 0
  of tCoal: CoalResearch
  of tUranium: UraniumResearch
  of tEmpty: 0

func baseCooldown*(kind: UnitKind): int =
  if kind == ukWorker: WorkerCooldown else: CartCooldown

func cargoCap*(kind: UnitKind): int =
  if kind == ukWorker: WorkerCargo else: CartCargo

func nightUpkeep*(kind: UnitKind): int =
  if kind == ukWorker: WorkerUpkeep else: CartUpkeep
