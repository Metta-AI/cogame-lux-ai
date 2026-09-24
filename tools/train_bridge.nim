## Persistent numeric decisions over the production Lux AI simulator.

import std/[json, os]
import lux/[sim, decide, llm]

const
  Variants = ["duel", "skirmish", "scarcity"]
  Mines = [
    [tWood, tCoal, tUranium], [tWood, tUranium, tCoal],
    [tCoal, tWood, tUranium], [tCoal, tUranium, tWood],
    [tUranium, tWood, tCoal], [tUranium, tCoal, tWood]]
  WorkerTargets = [0, 2, 4, 6, 8, 10, 14, 20, 30, 40]
  MaxSize = 16
  ValueCount = 2064

var
  game: SimServer
  progress: DecisionEngine
  variant: string
  cursor: int
  decisionId: int
  actions: array[2, JsonNode]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc options(width: int): JsonNode =
  result = newJArray()
  for value in 0 ..< width:
    result.add(%value)

proc heads(): JsonNode =
  %*[
    {"name": "stance", "choices": ["expand", "fuel", "research", "contest", "turtle"]},
    {"name": "mine", "choices": options(Mines.len)},
    {"name": "research", "choices": ["none", "coal", "uranium", "always"]},
    {"name": "build", "choices": ["auto", "city", "worker", "cart"]},
    {"name": "workers", "choices": WorkerTargets},
    {"name": "carts", "choices": options(MaxCarts + 1)},
    {"name": "focus_enabled", "choices": [0, 1]},
    {"name": "x", "choices": options(game.config.mapSize)},
    {"name": "y", "choices": options(game.config.mapSize)},
    {"name": "night", "choices": ["shelter", "mine", "haul"]}
  ]

proc directiveAction(directive: Directive): JsonNode =
  var mine = -1
  for i, order in Mines:
    if directive.mine == order: mine = i
  doAssert mine >= 0
  %*{"stance": $directive.stance, "mine": mine,
    "research": $directive.research, "build": $directive.build,
    "workers": directive.workers, "carts": directive.carts,
    "focus_enabled": (if directive.hasFocus: 1 else: 0),
    "x": (if directive.hasFocus: directive.focusX else: 0),
    "y": (if directive.hasFocus: directive.focusY else: 0),
    "night": $directive.night}

proc actionDirective(action: JsonNode): Directive =
  result = defaultDirective()
  for value in Stance:
    if $value == action["stance"].getStr(): result.stance = value
  result.mine = Mines[action["mine"].getInt()]
  for value in ResearchTarget:
    if $value == action["research"].getStr(): result.research = value
  for value in BuildOrder:
    if $value == action["build"].getStr(): result.build = value
  result.workers = action["workers"].getInt()
  result.carts = action["carts"].getInt()
  result.hasFocus = action["focus_enabled"].getInt() == 1
  result.focusX = action["x"].getInt()
  result.focusY = action["y"].getInt()
  for value in NightPolicy:
    if $value == action["night"].getStr(): result.night = value

proc currentDecision(): JsonNode =
  let seat = cursor
  let story = progress.snapshot(game, seat)
  let observation = game.seatObservation(seat, story.since,
    story.cities, story.workers, story.carts, story.lostTiles,
    story.lostUnits, story.story)
  var properties = newJObject()
  for head in heads():
    properties[head["name"].getStr()] = %*{"enum": head["choices"]}
  %*{"kind": "decision", "game": "lux-ai", "decision_id": decisionId,
    "seat": seat, "engine_seat": seat, "turn": game.world.turn,
    "semantic_view": observation, "inbox": [],
    "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage("", $observation)}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": ["stance", "mine", "research", "build", "workers",
        "carts", "focus_enabled", "x", "y", "night"]},
    "typed_question": newJNull()}

proc encoding(): JsonNode =
  let world = game.world
  var values = newJArray()
  for name in Variants: values.add(%(if variant == name: 1 else: 0))
  for seat in 0 .. 1: values.add(%(if cursor == seat: 1 else: 0))
  values.add(%(float(world.turn) / float(game.config.maxTurns)))
  for seat in 0 .. 1:
    values.add(%(float(world.cities.tileCount(Team(seat))) / 256.0))
    values.add(%(float(world.units.countOf(Team(seat), ukWorker)) / 40.0))
    values.add(%(float(world.units.countOf(Team(seat), ukCart)) / 10.0))
    values.add(%(float(world.researchPoints[seat]) / 200.0))
    values.add(%(float(world.cities.totalFuel(Team(seat))) / 100000.0))
  for y in 0 ..< MaxSize:
    for x in 0 ..< MaxSize:
      if x >= world.board.size or y >= world.board.size:
        for field in 0 ..< 8: values.add(%0)
        continue
      let cell = world.board.cellIndex(x, y)
      values.add(%(float(ord(world.board.terrain[cell])) / 3.0))
      values.add(%(float(world.board.amount[cell]) / 500.0))
      values.add(%(float(world.board.road[cell]) / 6.0))
      values.add(%(float(world.cities.teamOfCell[cell] + 1) / 2.0))
      for team in 0 .. 1:
        for kind in UnitKind:
          var count = 0
          for unit in world.units.list:
            if unit.cell == cell and ord(unit.team) == team and unit.kind == kind:
              inc count
          values.add(%(float(count) / 10.0))
  doAssert values.len == ValueCount
  %*{"decision_id": decisionId, "values": values,
    "action_heads": heads()}

proc reset(request: JsonNode, manifestPath: string): JsonNode =
  doAssert request["players"].getInt() == 2
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %seedOf(request["seed"].getStr())
  var config = defaultGameConfig()
  config.update(variantConfig)
  config.validate()
  game = initSimServer(config)
  game.beginPlaying()
  progress = DecisionEngine()
  cursor = 0
  decisionId = 0
  currentDecision()

proc teacher(): JsonNode =
  let directive = scriptedDirective(game.world, blForester, cursor)
  %*{"response": $directiveAction(directive)}

proc step(request: JsonNode): JsonNode =
  doAssert request["decision_id"].getInt() == decisionId
  let action = parseJson(request["response"].getStr())
  for head in heads():
    let name = head["name"].getStr()
    doAssert action[name] in head["choices"], "action is masked: " & name
  actions[cursor] = action
  inc cursor
  inc decisionId
  if cursor == 2:
    for seat in 0 .. 1:
      game.setDirective(seat, actionDirective(actions[seat]))
    game.step()
    while game.phase == Playing and not game.isDirectiveTurn(game.world.turn):
      game.step()
    cursor = 0
  let observation = if game.phase == GameOver:
    doAssert game.reason == erComplete, game.stopDetail
    var scores = newJObject()
    var utilities = newJObject()
    for seat in 0 .. 1:
      let score = game.outcome.scoreOf(seat)
      scores[$seat] = %score
      utilities[$seat] = %(2.0 * score - 1.0)
    %*{"kind": "terminal", "scores": scores, "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: lux-train-bridge MANIFEST VARIANT", 1)
  let manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in Variants
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request, manifestPath)
      of "encode": encoding()
      of "teacher": teacher()
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
