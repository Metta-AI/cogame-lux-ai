## The game server: mummy HTTP + websocket, the `COGAME_*` runtime contract,
## the join/auth path, the directive loop, the wall-clock stop and the artifact
## write. Forked from coworld-ctf's `src/ctf/server.nim`.
##
## The certifier's browser probes are served FOR REAL and are registered before
## any catch-all asset route: `GET /client/player?slot=&token=` (token-checked,
## and it must NOT open the player socket — the lantern 0.1.1 cert probe),
## `GET /client/global`, the `/global` websocket's first message, and
## `/healthz` — all kept answering for a bounded ~20 s grace after the
## artifacts are written (lantern 0.1.3). Global broadcasts are
## fire-and-forget, so a slow spectator can never stall the episode.

import std/[json, locks, monotimes, os, strutils, tables, times]

import bitworld/[runtime, spriteprotocol]
import mummy

import broadcast, decide, directives, global, replay_runtime, replays,
  sim, wire_constants

const
  HealthPath = "/healthz"
  PlayerSocketPath = "/player"
  GlobalSocketPath = "/global"
  ReplaySocketPath = "/replay"
  RewardSocketPath = "/reward"
  ClientPlayerPath = "/client/player"
  ClientGlobalPath = "/client/global"
  ClientReplayPath = "/client/replay"
  ReplayDataPath = "/replay-data"
  ShutdownGraceSeconds = 20
    ## The runner pings `/global` and `/healthz` AFTER the player pods start,
    ## and a short episode may already have exited. Keep answering for this
    ## long after the artifacts are written, then exit; the runner waits on
    ## process exit anyway (lantern 0.1.3 -> fixed in 0.1.4).

  BroadcastPage = staticRead("../../client/replay_broadcast.html")
  ClientProbePage = """<!doctype html><html><head><meta charset="utf-8">
<title>lux-ai</title></head><body style="background:#12100e;color:#f2e8d8;
font:14px system-ui;padding:2rem"><h1>lux-ai</h1>
<p>This seat is driven by its policy container over the websocket at
<code>/player?slot=&amp;token=</code>. This page is the platform's HTTP
contract probe and deliberately opens no socket.</p></body></html>"""

type
  Connection = object
    kind: int          ## 0 player, 1 global/replay, 2 reward
    slot: int
    state: GlobalViewerState

  AppState = object
    lock: Lock
    connections: Table[int, Connection]
    nextConnection: int
    sockets: Table[int, WebSocket]
    seatSocket: array[2, int]
    tokens: array[2, string]
    pendingChat: seq[tuple[slot: int, text: string]]
    viewerMessages: seq[tuple[id: int, text: string]]
    replayBytes: string
    shuttingDown: bool

var appState: AppState

proc initAppState() =
  initLock(appState.lock)
  appState.connections = initTable[int, Connection]()
  appState.sockets = initTable[int, WebSocket]()
  appState.nextConnection = 1
  appState.seatSocket = [-1, -1]

proc containsToken(value, token: string): bool =
  for part in value.split(','):
    if part.strip().toLowerAscii() == token.toLowerAscii():
      return true
  false

proc isWebSocketUpgrade(request: Request): bool =
  ## mummy keeps its own header-token helper private, so the upgrade probe is
  ## spelled out here rather than reached for through an internal import.
  var headers = request.headers
  containsToken(headers["Connection"], "Upgrade") and
    containsToken(headers["Upgrade"], "websocket")

proc queryValue(request: Request, name: string): string =
  request.queryParams.getOrDefault(name, "")

proc slotOf(request: Request): int =
  try: parseInt(request.queryValue("slot")) except CatchableError: -1

proc respondText(request: Request, code: int, body: string,
    contentType = "text/plain; charset=utf-8") =
  var headers: HttpHeaders
  headers["Content-Type"] = contentType
  headers["Cache-Control"] = "no-cache"
  request.respond(code, headers, body)

proc tokenOk(slot: int, token: string): bool =
  {.gcsafe.}:
    withLock appState.lock:
      if slot < 0 or slot > 1:
        return false
      if appState.tokens[slot].len == 0:
        return true
      return appState.tokens[slot] == token

proc httpHandler(request: Request) {.gcsafe.} =
  if request.path == HealthPath and request.httpMethod == "GET":
    request.respondText(200, "healthy")
    return
  if request.path == PlayerSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let slot = request.slotOf()
    if not tokenOk(slot, request.queryValue("token")):
      request.respondText(403, "bad slot or token\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        let id = appState.nextConnection
        inc appState.nextConnection
        appState.connections[id] = Connection(kind: 0, slot: slot)
        appState.sockets[id] = websocket
        appState.seatSocket[slot] = id
    echo "lux-ai: player connected on slot ", slot
    return
  if request.path in [GlobalSocketPath, ReplaySocketPath] and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    if request.queryValue("slot").len > 0 or request.queryValue("token").len > 0:
      request.respondText(403, "viewer sockets take no player credentials\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        let id = appState.nextConnection
        inc appState.nextConnection
        appState.connections[id] =
          Connection(kind: 1, slot: -1, state: initGlobalViewerState())
        appState.sockets[id] = websocket
    return
  if request.path == RewardSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        let id = appState.nextConnection
        inc appState.nextConnection
        appState.connections[id] = Connection(kind: 2, slot: -1)
        appState.sockets[id] = websocket
    return
  # --- the certifier's HTTP contract probes, before any catch-all ----------
  if request.path == ClientPlayerPath and request.httpMethod == "GET":
    let slot = request.slotOf()
    if not tokenOk(slot, request.queryValue("token")):
      request.respondText(403, "bad slot or token\n")
      return
    request.respondText(200, ClientProbePage, "text/html; charset=utf-8")
    return
  if request.path in [ClientGlobalPath, ClientReplayPath] and
      request.httpMethod == "GET":
    request.respondText(200, spliceWireConstants(BroadcastPage),
      "text/html; charset=utf-8")
    return
  if request.path == ReplayDataPath and request.httpMethod == "GET":
    var body = ""
    {.gcsafe.}:
      withLock appState.lock:
        body = appState.replayBytes
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    request.respond(if body.len > 0: 200 else: 404, headers, body)
    return
  request.respondText(200, "lux-ai server")

proc websocketHandler(
  websocket: WebSocket, event: WebSocketEvent, message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    withLock appState.lock:
      var found = -1
      for id, socket in appState.sockets:
        if socket == websocket:
          found = id
          break
      if found < 0:
        return
      case event
      of CloseEvent:
        let connection = appState.connections[found]
        if connection.kind == 0 and connection.slot in 0 .. 1 and
            appState.seatSocket[connection.slot] == found:
          appState.seatSocket[connection.slot] = -1
        appState.connections.del(found)
        appState.sockets.del(found)
      of MessageEvent:
        let connection = appState.connections[found]
        if connection.kind == 0:
          for item in parseSpriteClientMessages(message.data):
            if item.kind == SpriteClientChatMessage and item.text.len > 0:
              appState.pendingChat.add((connection.slot, item.text))
        elif connection.kind == 1:
          appState.viewerMessages.add((found, message.data))
      else:
        discard

type ServerThreadArgs = object
  server: ptr Server
  address: string
  port: int

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc parseRegistration(
  text: string
): tuple[ok: bool, prompt, scripted, policy: string] =
  ## A seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","policy":"…","prompt":"…","scripted":"forester"|null}
  ## Anything that is not that object is not a registration — and this game has
  ## no inter-seat channel, so any other chat text from a seat is DROPPED.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform's CLOSED payload — exactly `{"message","failed_policy_index"}`,
  ## lowest missing slot only. Best-effort: a declaration write failure must
  ## never mask what follows, and outside the platform this is a no-op.
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    echo "lux-ai: player-failure declaration failed: ", error.msg

proc filePathFromEnv(name: string): string =
  let uri = getEnv(name)
  if uri.len == 0:
    return ""
  if uri.startsWith("file://"):
    return uri[7 .. ^1]
  raise newException(ValueError, name & " must be a file:// path, got: " & uri)

proc runServerLoop*(
  host = "0.0.0.0",
  port = 8080,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayBytes = "",
  runtimeConfig = RuntimeConfig()
) =
  initAppState()
  let replayLoaded = loadReplayBytes.len > 0
  var
    config = initialConfig
    replayData: ReplayData
    initialized: InitializedReplay
  if replayLoaded:
    try:
      replayData = parseLuxReplay(loadReplayBytes)
      initialized = initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
      config = initialized.config
    except CatchableError as error:
      echo "lux-ai: replay load failed (serving without replay): ", error.msg
  config.validate()

  var sim =
    if replayLoaded and initialized.sim.config.mapSize > 0: initialized.sim
    else: initSimServer(config)
  var player =
    if replayLoaded: initialized.player else: ReplayPlayer()
  var tracker =
    if replayLoaded: initialized.tracker else: initBroadcastTracker()

  withLock appState.lock:
    for seat in 0 .. 1:
      appState.tokens[seat] =
        if seat < config.tokens.len: config.tokens[seat] else: ""

  let
    eventsPath = filePathFromEnv("COGAME_EVENTS_URI")
    metricsPath = filePathFromEnv("COGAME_METRICS_URI")
  var writer = openReplayWriter(saveReplayPath, $config.configJson(),
    LuxReplaySpec)
  defer: writer.closeReplayWriter()

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 2)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()
  echo "lux-ai: listening on ", host, ":", port

  var
    engine = if replayLoaded: DecisionEngine() else: initDecisionEngine(sim)
    episodeStart = getMonoTime()
    lastTick = getMonoTime()
    joinWritten: array[2, bool]
    failureDeclared = false
    lastDirectiveTurn = -1
    artifactsWritten = false
    doneAt = getMonoTime()
    globalStates = initTable[int, GlobalViewerState]()

  proc drainPlayerChat() =
    var chats: seq[tuple[slot: int, text: string]]
    withLock appState.lock:
      chats = appState.pendingChat
      appState.pendingChat.setLen(0)
    for chat in chats:
      let registration = parseRegistration(chat.text)
      if not registration.ok:
        continue                       ## no inter-seat channel: dropped
      let seat = chat.slot
      if seat notin 0 .. 1:
        continue
      if engine.seats[seat].registered:
        continue
      engine.seats[seat].registered = true
      engine.seats[seat].prompt = registration.prompt.truncateRunes(MaxPromptRunes)
      engine.seats[seat].isLlm = registration.prompt.len > 0
      engine.seats[seat].baseline = parseBaseline(registration.scripted)
      engine.seats[seat].label =
        if registration.policy.len > 0:
          registration.policy.truncateRunes(MaxPolicyLabelRunes)
        elif engine.seats[seat].isLlm: "lux-ai-llm"
        else: "lux-ai-" & $engine.seats[seat].baseline
      sim.seats[seat].isLlm = engine.seats[seat].isLlm
      sim.seats[seat].policyLabel = engine.seats[seat].label
      sim.seats[seat].baseline = $engine.seats[seat].baseline
      sim.seats[seat].registered = true
      ## LOUDLY: a seat that registers as scripted while a champion was
      ## expected is the grf-football round-2 scar, and the only way to see it
      ## is in the game log (the register packet can be lost after join).
      echo "lux-ai: seat ", seat, " registered as ",
        (if engine.seats[seat].isLlm: "LLM" else: "scripted " &
          $engine.seats[seat].baseline), " (", engine.seats[seat].label, ")"
      let record = $registerRecord(seat, cogAlias(seat),
        engine.seats[seat].label,
        (if engine.seats[seat].isLlm: "llm" else: "scripted"),
        $engine.seats[seat].baseline)
      writer.writeChat(tickTime(sim.tickCount, ReplayFps), seat, record)

  proc syncSeats() =
    withLock appState.lock:
      for seat in 0 .. 1:
        let connected = appState.seatSocket[seat] >= 0
        if connected and not sim.seats[seat].joined:
          sim.seats[seat].joined = true
          sim.seats[seat].connected = true
          sim.seats[seat].dead = false
        elif not connected and sim.seats[seat].joined:
          sim.seats[seat].connected = false
    for seat in 0 .. 1:
      if sim.seats[seat].joined and not joinWritten[seat]:
        joinWritten[seat] = true
        writer.writeJoin(tickTime(sim.tickCount, ReplayFps), seat,
          sim.seats[seat].name, seat, appState.tokens[seat])

  proc broadcast(packet: seq[uint8]) =
    ## Fire-and-forget: a slow spectator can never stall the episode.
    ##
    ## SEATS GET THE FRAME TOO. `fastMode` means a seat sends no inputs, but it
    ## must still SEE something: its container's receive loop is what keeps it
    ## alive and what tells it the episode ended (the socket closing after a
    ## frame). A seat that is never sent a frame blocks in `receiveMessage`
    ## until the game exits and then cannot tell "the episode is over" from
    ## "the connection never worked" — which is how a player container ends up
    ## re-dialling past the certifier's patience.
    let blob = blobFromBytes(packet)
    withLock appState.lock:
      for id, connection in appState.connections:
        if connection.kind == 2:
          continue
        try:
          appState.sockets[id].send(blob, BinaryMessage)
        except CatchableError:
          discard

  proc writeArtifacts() =
    if artifactsWritten:
      return
    artifactsWritten = true
    let record = sim.resultRecord()
    writer.writeChat(tickTime(sim.tickCount, ReplayFps), 0, record)
    writer.flushReplayWriter()
    writer.closeReplayWriter()
    try:
      writeCogameEnv("COGAME_RESULTS_URI", sim.luxResultsJson(),
        "application/json")
    except CatchableError as error:
      echo "lux-ai: results write failed: ", error.msg
    if saveReplayPath.len > 0 and fileExists(saveReplayPath):
      try:
        let bytes = readFile(saveReplayPath)
        withLock appState.lock:
          appState.replayBytes = bytes
        writeCogameFileToUri(getEnv("COGAME_SAVE_REPLAY_URI"), saveReplayPath,
          "application/octet-stream", "COGAME_SAVE_REPLAY_URI")
      except CatchableError as error:
        echo "lux-ai: replay upload failed: ", error.msg
    if eventsPath.len > 0:
      try:
        var extra = %*{
          "gameName": GameName,
          "protocol": ReplayProtocol,
          "results": parseJson(sim.luxResultsJson())}
        writeFile(eventsPath,
          eventsJsonl(sim.world.events, sim.tickCount, extra))
      except CatchableError as error:
        echo "lux-ai: events write failed: ", error.msg
    if metricsPath.len > 0:
      try:
        writeFile(metricsPath, $(%*{
          "ticks": sim.tickCount,
          "turns": sim.world.turn,
          "wall_clock_s": (getMonoTime() - episodeStart).inSeconds,
          "llm_turns": [sim.llmTurns[0], sim.llmTurns[1]],
          "fallback_turns": [sim.fallbackTurns[0], sim.fallbackTurns[1]]}))
      except CatchableError as error:
        echo "lux-ai: metrics write failed: ", error.msg
    echo "lux-ai: episode settled ", sim.reason, "/", sim.endRule,
      " after ", sim.world.turn, " turns"

  # ------------------------------------------------------------------ loop
  while true:
    let now = getMonoTime()
    let elapsed = (now - episodeStart).inSeconds.int

    if replayLoaded:
      var seekTicks: seq[int] = @[]
      var commands: seq[char] = @[]
      var messages: seq[tuple[id: int, text: string]]
      withLock appState.lock:
        messages = appState.viewerMessages
        appState.viewerMessages.setLen(0)
      for message in messages:
        var state = globalStates.getOrDefault(message.id,
          initGlobalViewerState())
        state.applyGlobalViewerMessage(message.text)
        if state.replaySeekTick >= 0:
          seekTicks.add(state.replaySeekTick)
        for command in state.replayCommands:
          commands.add(command)
        state.replayCommands.setLen(0)
        state.replaySeekTick = -1
        globalStates[message.id] = state
      let events = player.advanceReplayFrame(sim, tracker, seekTicks, commands)
      var viewer = globalStates.getOrDefault(0, initGlobalViewerState())
      var nextViewer: GlobalViewerState
      broadcast(buildReplayViewerPacket(sim, player, tracker, viewer,
        nextViewer, events))
      globalStates[0] = nextViewer
      sleep(max(1, 1000 div ReplayFps))
      continue

    drainPlayerChat()
    syncSeats()

    # The engine's own hard stop, checked before anything else this iteration.
    if sim.phase == Playing and elapsed >= config.wallClockBudgetSeconds:
      writer.writeInputPacket(sim.tickCount, 0,
        controlPacket(InputWallClockStop))
      writer.writeChat(tickTime(sim.tickCount, ReplayFps), 0,
        stopRecord(sim.world.turn))
      sim.applyWallClockStop()
      echo "lux-ai: wall-clock budget of ", config.wallClockBudgetSeconds,
        " s reached; settling from the standing at turn ", sim.world.turn

    if sim.phase == Lobby:
      let joined = sim.seats[0].joined and sim.seats[1].joined
      if (joined and sim.tickCount >= config.startWaitTicks) or
          sim.tickCount >= config.lobbyJoinTimeoutTicks:
        if not joined and not failureDeclared:
          failureDeclared = true
          for seat in 0 .. 1:
            if not sim.seats[seat].joined:
              sim.seats[seat].dead = true
              declarePlayerFailure(seat,
                "player did not connect before the lobby timeout")
              break
        writer.writeInputPacket(sim.tickCount, 0, controlPacket(InputStart))
        sim.beginPlaying()
      else:
        writer.writeHash(uint32(sim.tickCount), sim.gameHash())
        inc sim.tickCount
        sleep(max(1, 1000 div TargetFps))
        continue

    if sim.phase == Playing:
      let turn = sim.world.turn
      if sim.isDirectiveTurn(turn) and turn != lastDirectiveTurn:
        lastDirectiveTurn = turn
        let records = engine.turn(sim, elapsed)
        for seat in 0 .. 1:
          writer.writeInputPacket(sim.tickCount, seat,
            directivePacket(sim.world.directiveBytes[seat]))
        for record in records:
          writer.writeChat(tickTime(sim.tickCount, ReplayFps), 0, record)
      writer.writeHash(uint32(sim.tickCount), sim.gameHash())
      sim.step()
    elif sim.phase == GameOver:
      writer.writeHash(uint32(sim.tickCount), sim.gameHash())
      inc sim.tickCount

    var events = newJArray()
    sim.stepEvents(tracker, events)
    var viewer = globalStates.getOrDefault(0, initGlobalViewerState())
    var nextViewer: GlobalViewerState
    var packet = buildBoardPacket(sim, viewer, nextViewer)
    globalStates[0] = nextViewer
    packet.addChrome(sim.buildStateJson(tracker, events, false, 1,
      max(1, sim.tickCount), false, false, -1, sim.gameStartTick, false, false))
    broadcast(packet)

    if sim.phase == GameOver and not artifactsWritten:
      writeArtifacts()
      doneAt = getMonoTime()
    if artifactsWritten:
      ## The bounded post-artifact grace: `/healthz` and `/global` keep
      ## answering (the runner pings them AFTER the player pods start, and a
      ## short episode may already have exited — lantern 0.1.3), but the sim
      ## stops advancing so the recorded tick span is exactly the episode.
      while (getMonoTime() - doneAt).inSeconds.int < ShutdownGraceSeconds:
        sleep(200)
      break
    if sim.phase != Playing or not config.fastMode:
      sleep(max(1, 1000 div TargetFps))
    lastTick = now
  discard lastTick
  quit(0)
