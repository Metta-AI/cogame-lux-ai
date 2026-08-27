## Claude-backed strategy command. A policy is just a prompt: the game server
## composes the seat's observation plus that seat's PLAYER_PROMPT and asks
## Claude what its side does for the next ten turns.
##
## Forked from coworld-ctf's `src/ctf/llm.nim` with NO behaviour change — the
## credential ladder, the Bedrock model rotation, the fence-tolerant JSON
## extraction and the rune-boundary truncation are all scar tissue from real
## hosted failures.
##
## lux-ai is a SIMULTANEOUS-decision game, so both seats' calls go out as ONE
## parallel batch per directive turn (`curly.makeRequests`). Seats are never
## queried sequentially: that is what keeps 36 directive turns inside the
## wall-clock budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every directive turn falls
## back to the scripted layer INSTANTLY, with no network wait — which is what
## lets offline certification finish in seconds.

import std/[json, os, strutils]

import bitworld/runtime
import curly

import directives, sim_config, sim_types

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside the
      ## same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a refused call.

  LlmError* = object of LuxError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "lux-ai llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. `us.anthropic.claude-sonnet-4-6` is deliberately NOT a candidate: it
  ## times out on every sidecar call (cogame-raid round 2, 2026-08-23), and one
  ## haiku throttle then cascades into a whole episode of scripted fallbacks
  ## because the retry burns the turn.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "lux-ai llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "lux-ai llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "lux-ai llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim: "LLM provider is unavailable".
    echo "lux-ai llm: no credentials — the LLM provider is unavailable; ",
      "every directive turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      ## Nothing left to rotate to: a second call this turn would be refused
      ## the same way, so the turn loop must not spend its retry on it.
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))
  if result.len > MaxReplyBytes:
    result = result.truncateRunes(MaxReplyBytes)

const SystemPrompt* = """
You command ONE SIDE of a Lux AI Season 1 game on a 16 by 16 mirrored island. You
are RED or BLUE; the other side is played by someone you cannot talk to and whose
plans you cannot see. Everything else is public: the whole map, every unit, every
city, both research counts, every resource amount.

THE CLOCK
360 turns. Each 40-turn cycle is 30 turns of DAY then 10 turns of NIGHT.
Nine cycles. There are no surprises in the clock; plan around it.

THE RULES THAT DECIDE GAMES
- Workers mine 20 wood, 5 coal or 2 uranium per turn from any tile they stand on
  or stand next to. A worker carries 100 units total. A cart carries 2000 and
  cannot mine at all, but it paves roads where it drives and roads make everyone
  on them move twice as often.
- Fuel value: 1 wood = 1, 1 coal = 10, 1 uranium = 40. Coal needs 50 research
  points, uranium needs 200. A city tile spends its whole turn to earn ONE
  research point, so research costs you workers.
- A unit standing on your own city tile empties its cargo into that city as fuel,
  every turn, automatically.
- A worker holding 100 units of anything can BUILD A CITY TILE on an empty square
  (not on a resource square). That is how you score.
- You may never own more units than you own city tiles.
- EVERY NIGHT TURN each city pays 23 fuel per tile, minus 5 for each pair of its
  tiles that touch. A 6-tile blob in a line pays 113 a turn, 1130 for the night.
  A city that cannot pay is DESTROYED ENTIRELY, every tile, that instant.
  Units outside a city burn their own cargo at night: 4 fuel a worker, 10 a cart.
  A unit that cannot pay dies. Units inside your city pay nothing.
- Wood regrows about 2% a turn, but a wood tile mined to exactly zero is gone for
  good. Coal and uranium never regrow.

HOW YOU PLAY
You do NOT move units. Every 10 turns you send ONE strategy object, and a
deterministic controller executes it for the next 10 turns: it assigns every
worker to the best tile of your chosen resource, walks them home to deposit,
plants city tiles when they are full, drives your carts, and tells your city
tiles what to build. It never disobeys and it never improvises a strategy.

WINNING
Most city tiles standing at turn 360. Ties go to most units, then most fuel.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with { and end
with }. No prose, no markdown, no code fences.
{"stance":"expand|fuel|research|contest|turtle",
 "mine":["wood","coal","uranium"],          the order your workers prefer
 "research":"none|coal|uranium|always",     how far city tiles research first
 "build":"auto|city|worker|cart",           what an idle city tile does
 "workers":6, "carts":1,                    target counts, 0-40 and 0-10
 "focus":[x,y] or null,                     where the expansion effort aims
 "night":"shelter|mine|haul",               what units do during night turns
 "note":"<=160 chars, for the audience watching the replay - the other side
         never sees it"}

WHAT THE STANCES DO
expand  - workers that fill up plant city tiles near your cities and near `focus`.
fuel    - workers that fill up walk home and deposit instead of building.
research- as `fuel`, and city tiles keep researching past the target.
contest - as `expand`, but city tiles are planted next to the resource tiles
          NEAREST THE OPPONENT, to deny them.
turtle  - nobody builds; everything hauls into the largest city you own.
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how much
  ## weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## observation (built server-side — see decide.nim).
  operatorBlock(operatorPrompt) & viewJson
