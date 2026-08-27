## GameConfig lifecycle: defaults, `update` from the runner's config JSON, and
## `validate`. Forked from coworld-ctf's `src/ctf/sim_config.nim`.
##
## Every field here is declared in `coworld_manifest_template.json`'s
## `game.config_schema`, and `tests/test_lux_manifest.nim` asserts the two sets
## agree in BOTH directions — a knob the schema does not declare is a knob the
## platform cannot set, and a schema field the sim ignores is a lie.

import std/[json, strutils]

import sim_types

type
  GameConfig* = object
    # --- seats -----------------------------------------------------------
    numAgents*: int
    minPlayers*: int
    teams*: int
    cogsPerTeam*: int
    playerNames*: seq[string]
    slots*: seq[int]
    tokens*: seq[string]

    # --- board -----------------------------------------------------------
    seed*: int
    mapSize*: int
    woodClusters*: int
    coalClusters*: int
    uraniumClusters*: int
    woodStart*: int
    coalStart*: int
    uraniumStart*: int

    # --- clock -----------------------------------------------------------
    maxTurns*: int
    cycleLength*: int
    dayLength*: int
    directiveEvery*: int

    # --- rules (transcribed S1 constants, all overridable) ---------------
    cityCost*: int
    workerCargo*: int
    cartCargo*: int
    woodRate*: int
    coalRate*: int
    uraniumRate*: int
    coalResearch*: int
    uraniumResearch*: int
    cityUpkeepPerTile*: int
    cityAdjacencyDiscount*: int
    workerUpkeep*: int
    cartUpkeep*: int
    workerCooldown*: int
    cartCooldown*: int
    cityCooldown*: int
    maxRoad*: int

    # --- decision layer ---------------------------------------------------
    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    model*: string
    maxOutputTokens*: int

    # --- lifecycle --------------------------------------------------------
    lobbyJoinTimeoutTicks*: int
    startWaitTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    fullyObservable*: bool

  ConfigError* = object of LuxError

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    numAgents: 2,
    minPlayers: 2,
    teams: 2,
    cogsPerTeam: 1,
    playerNames: @["Red", "Blue"],
    slots: @[],
    tokens: @[],
    seed: 1734029581,
    mapSize: 16,
    woodClusters: 4,
    coalClusters: 2,
    uraniumClusters: 1,
    woodStart: 300,
    coalStart: 400,
    uraniumStart: 325,
    maxTurns: 360,
    cycleLength: 40,
    dayLength: 30,
    directiveEvery: 10,
    cityCost: CityCost,
    workerCargo: WorkerCargo,
    cartCargo: CartCargo,
    woodRate: WoodRate,
    coalRate: CoalRate,
    uraniumRate: UraniumRate,
    coalResearch: CoalResearch,
    uraniumResearch: UraniumResearch,
    cityUpkeepPerTile: CityUpkeepPerTile,
    cityAdjacencyDiscount: CityAdjacencyDiscount,
    workerUpkeep: WorkerUpkeep,
    cartUpkeep: CartUpkeep,
    workerCooldown: WorkerCooldown,
    cartCooldown: CartCooldown,
    cityCooldown: CityCooldown,
    maxRoad: MaxRoad,
    attempt1Ms: 7000,
    retryMs: 3000,
    turnBudgetMs: 11000,
    turnSpacingMs: 6000,
    wallClockBudgetSeconds: 660,
    model: "",
    maxOutputTokens: 900,
    lobbyJoinTimeoutTicks: 2400,
    startWaitTicks: 48,
    gameOverTicks: 72,
    fastMode: true,
    showPlayerLabels: false,
    fullyObservable: true
  )

proc readInt(node: JsonNode, current: int): int =
  if node.isNil or node.kind == JNull:
    return current
  case node.kind
  of JInt: int(node.getBiggestInt())
  of JFloat: int(node.getFloat())
  of JString:
    try: parseInt(node.getStr().strip())
    except CatchableError: current
  else: current

proc readBool(node: JsonNode, current: bool): bool =
  if node.isNil or node.kind == JNull:
    return current
  case node.kind
  of JBool: node.getBool()
  of JInt: node.getBiggestInt() != 0
  of JString: node.getStr().strip().toLowerAscii() in ["1", "true", "yes"]
  else: current

proc update*(config: var GameConfig, node: JsonNode) =
  ## Applies the runner's resolved config JSON. Absent keys keep their default,
  ## which is what lets a variant name only the fields it varies.
  if node.isNil or node.kind != JObject:
    return
  config.numAgents = readInt(node{"num_agents"}, config.numAgents)
  config.minPlayers = readInt(node{"minPlayers"}, config.minPlayers)
  config.teams = readInt(node{"teams"}, config.teams)
  config.cogsPerTeam = readInt(node{"cogsPerTeam"}, config.cogsPerTeam)
  config.seed = readInt(node{"seed"}, config.seed)
  config.mapSize = readInt(node{"mapSize"}, config.mapSize)
  config.woodClusters = readInt(node{"woodClusters"}, config.woodClusters)
  config.coalClusters = readInt(node{"coalClusters"}, config.coalClusters)
  config.uraniumClusters =
    readInt(node{"uraniumClusters"}, config.uraniumClusters)
  config.woodStart = readInt(node{"woodStart"}, config.woodStart)
  config.coalStart = readInt(node{"coalStart"}, config.coalStart)
  config.uraniumStart = readInt(node{"uraniumStart"}, config.uraniumStart)
  config.maxTurns = readInt(node{"maxTurns"}, config.maxTurns)
  config.cycleLength = readInt(node{"cycleLength"}, config.cycleLength)
  config.dayLength = readInt(node{"dayLength"}, config.dayLength)
  config.directiveEvery = readInt(node{"directiveEvery"}, config.directiveEvery)
  config.cityCost = readInt(node{"cityCost"}, config.cityCost)
  config.workerCargo = readInt(node{"workerCargo"}, config.workerCargo)
  config.cartCargo = readInt(node{"cartCargo"}, config.cartCargo)
  config.woodRate = readInt(node{"woodRate"}, config.woodRate)
  config.coalRate = readInt(node{"coalRate"}, config.coalRate)
  config.uraniumRate = readInt(node{"uraniumRate"}, config.uraniumRate)
  config.coalResearch = readInt(node{"coalResearch"}, config.coalResearch)
  config.uraniumResearch =
    readInt(node{"uraniumResearch"}, config.uraniumResearch)
  config.cityUpkeepPerTile =
    readInt(node{"cityUpkeepPerTile"}, config.cityUpkeepPerTile)
  config.cityAdjacencyDiscount =
    readInt(node{"cityAdjacencyDiscount"}, config.cityAdjacencyDiscount)
  config.workerUpkeep = readInt(node{"workerUpkeep"}, config.workerUpkeep)
  config.cartUpkeep = readInt(node{"cartUpkeep"}, config.cartUpkeep)
  config.workerCooldown = readInt(node{"workerCooldown"}, config.workerCooldown)
  config.cartCooldown = readInt(node{"cartCooldown"}, config.cartCooldown)
  config.cityCooldown = readInt(node{"cityCooldown"}, config.cityCooldown)
  config.maxRoad = readInt(node{"maxRoad"}, config.maxRoad)
  config.attempt1Ms = readInt(node{"attempt1Ms"}, config.attempt1Ms)
  config.retryMs = readInt(node{"retryMs"}, config.retryMs)
  config.turnBudgetMs = readInt(node{"turnBudgetMs"}, config.turnBudgetMs)
  config.turnSpacingMs = readInt(node{"turnSpacingMs"}, config.turnSpacingMs)
  config.wallClockBudgetSeconds =
    readInt(node{"wallClockBudgetSeconds"}, config.wallClockBudgetSeconds)
  config.maxOutputTokens = readInt(node{"maxOutputTokens"}, config.maxOutputTokens)
  config.lobbyJoinTimeoutTicks =
    readInt(node{"lobbyJoinTimeoutTicks"}, config.lobbyJoinTimeoutTicks)
  config.startWaitTicks = readInt(node{"startWaitTicks"}, config.startWaitTicks)
  config.gameOverTicks = readInt(node{"gameOverTicks"}, config.gameOverTicks)
  config.fastMode = readBool(node{"fastMode"}, config.fastMode)
  config.showPlayerLabels =
    readBool(node{"showPlayerLabels"}, config.showPlayerLabels)
  config.fullyObservable =
    readBool(node{"fullyObservable"}, config.fullyObservable)
  if not node{"model"}.isNil and node{"model"}.kind == JString:
    config.model = node{"model"}.getStr()
  let players = node{"players"}
  if not players.isNil and players.kind == JArray and players.len > 0:
    config.playerNames = @[]
    for entry in players:
      if entry.kind == JObject:
        config.playerNames.add(entry{"name"}.getStr())
      elif entry.kind == JString:
        config.playerNames.add(entry.getStr())
  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for entry in tokens:
      config.tokens.add(entry.getStr())
  let slots = node{"slots"}
  if not slots.isNil and slots.kind == JArray:
    config.slots = @[]
    for entry in slots:
      config.slots.add(readInt(entry, 0))

proc validate*(config: GameConfig) =
  ## Raises `ConfigError` on a config the engine cannot honour. The two
  ## whole-second checks are load-bearing: curl's `CURLOPT_TIMEOUT` is
  ## second-grained, so a sub-second deadline is not the deadline it claims.
  if config.numAgents != 2:
    raise newException(ConfigError,
      "lux-ai is a two-seat duel; num_agents must be 2, got " &
      $config.numAgents)
  if config.mapSize < 8 or config.mapSize > MaxMapSize or
      config.mapSize mod 2 != 0:
    raise newException(ConfigError,
      "mapSize must be even and within 8.." & $MaxMapSize)
  if config.maxTurns < 1:
    raise newException(ConfigError, "maxTurns must be positive")
  if config.cycleLength < 2 or config.dayLength < 1 or
      config.dayLength >= config.cycleLength:
    raise newException(ConfigError,
      "dayLength must be within 1 ..< cycleLength")
  if config.directiveEvery < 1:
    raise newException(ConfigError, "directiveEvery must be positive")
  if config.woodClusters < 0 or config.coalClusters < 0 or
      config.uraniumClusters < 0:
    raise newException(ConfigError, "cluster counts must not be negative")
  if config.attempt1Ms < 0 or config.attempt1Ms mod 1000 != 0:
    raise newException(ConfigError,
      "attempt1Ms must be a whole number of seconds (curl's CURLOPT_TIMEOUT " &
      "is second-grained), got " & $config.attempt1Ms)
  if config.retryMs < 0 or config.retryMs mod 1000 != 0:
    raise newException(ConfigError,
      "retryMs must be a whole number of seconds, got " & $config.retryMs)
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(ConfigError,
      "attempt1Ms + retryMs (" & $(config.attempt1Ms + config.retryMs) &
      ") must fit inside turnBudgetMs (" & $config.turnBudgetMs & ")")
  if config.wallClockBudgetSeconds < 1 or config.wallClockBudgetSeconds > 720:
    raise newException(ConfigError,
      "wallClockBudgetSeconds must be within 1..720 (60 % of the platform's " &
      "1200 s episodeTimeoutSeconds), got " & $config.wallClockBudgetSeconds)
  if config.maxRoad < 0 or config.maxRoad > MaxRoad:
    raise newException(ConfigError, "maxRoad must be within 0.." & $MaxRoad)

proc configJson*(config: GameConfig): JsonNode =
  ## The resolved config as it is written into the replay header. Everything a
  ## re-simulation needs, and the REAL player names (spectator side).
  result = %*{
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "teams": config.teams,
    "cogsPerTeam": config.cogsPerTeam,
    "seed": config.seed,
    "mapSize": config.mapSize,
    "woodClusters": config.woodClusters,
    "coalClusters": config.coalClusters,
    "uraniumClusters": config.uraniumClusters,
    "woodStart": config.woodStart,
    "coalStart": config.coalStart,
    "uraniumStart": config.uraniumStart,
    "maxTurns": config.maxTurns,
    "cycleLength": config.cycleLength,
    "dayLength": config.dayLength,
    "directiveEvery": config.directiveEvery,
    "cityCost": config.cityCost,
    "workerCargo": config.workerCargo,
    "cartCargo": config.cartCargo,
    "woodRate": config.woodRate,
    "coalRate": config.coalRate,
    "uraniumRate": config.uraniumRate,
    "coalResearch": config.coalResearch,
    "uraniumResearch": config.uraniumResearch,
    "cityUpkeepPerTile": config.cityUpkeepPerTile,
    "cityAdjacencyDiscount": config.cityAdjacencyDiscount,
    "workerUpkeep": config.workerUpkeep,
    "cartUpkeep": config.cartUpkeep,
    "workerCooldown": config.workerCooldown,
    "cartCooldown": config.cartCooldown,
    "cityCooldown": config.cityCooldown,
    "maxRoad": config.maxRoad,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnBudgetMs": config.turnBudgetMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "maxOutputTokens": config.maxOutputTokens,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "startWaitTicks": config.startWaitTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "fullyObservable": config.fullyObservable
  }
  var players = newJArray()
  for name in config.playerNames:
    players.add(%*{"name": name})
  result["players"] = players
  var slots = newJArray()
  for slot in config.slots:
    slots.add(%slot)
  result["slots"] = slots
  ## `tokens` is runner-managed and deliberately NOT echoed here: matriculate
  ## rejects a game_config that carries one, and a replay is a public artifact.
