## The player container (`/bin/lux-ai-player`): the thin seat registrar.
## Forked from coworld-ctf's `src/paintball_player.nim`.
##
## It reads `COWORLD_PLAYER_WS_URL` (legacy alias `COGAMES_ENGINE_WS_URL`),
## `PLAYER_PROMPT`, `PLAYER_SCRIPTED` and `PLAYER_POLICY_LABEL`, dials with
## bounded retries, and sends ONE Sprite v1 chat message carrying its
## registration. It makes NO LLM call: the decision happens in the GAME pod,
## which is where the coworld secret is injected.
##
## Registration is RE-SENT over the first few seconds because joins are
## slot-sequential and a seat whose slot is not the next open one is not
## admitted until the lower slot has joined (the paintball round-3 scar, where
## a champion played the baseline for a whole episode).
##
## It exits 0 ON A DEAD SOCKET: whisky's `receiveMessage` RAISES on a close
## frame and the game's `quit(0)` can outrun the flushed `done` frame, so a
## naive player exits 1 and fails certification intermittently (the raid 0.1.3
## scar).

import std/[json, os, strutils]

import bitworld/spriteprotocol
import whisky

import lux/[directives, sim_types]

const
  DialAttempts = 240
    ## The FIRST dial waits for the game container to come up.
  RedialAttempts = 10
    ## A re-dial after a mid-episode drop does not: the game is either there
    ## within a few seconds or the episode is over.
  DialDelayMs = 500
  RegistrationResends = 10
  ReceiveRetries = 2

proc socketUrl(): string =
  result = getEnv("COWORLD_PLAYER_WS_URL").strip()
  if result.len == 0:
    result = getEnv("COGAMES_ENGINE_WS_URL").strip()
  if result.len == 0:
    result = "ws://localhost:8080/player?slot=0&token=token-0"

proc registrationBlob(): string =
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
  var label = getEnv("PLAYER_POLICY_LABEL").strip()
  if label.len == 0:
    label =
      if prompt.len > 0: "lux-ai-prompt"
      elif scripted.len > 0: "lux-ai-" & scripted
      else: "lux-ai-forester"
  var payload = %*{
    "type": "register",
    "policy": label.truncateRunes(MaxPolicyLabelRunes),
    "prompt": prompt.truncateRunes(MaxPromptRunes)
  }
  if scripted.len > 0:
    payload["scripted"] = %scripted
  else:
    payload["scripted"] = newJNull()
  ## The chat channel is printable ASCII only, so the registration is sent as
  ## compact JSON with no newlines; the prompt is rune-truncated FIRST so the
  ## cut can never land inside a codepoint.
  blobFromSpriteChat($payload)

proc dial(url: string, attempts: int): WebSocket =
  for attempt in 1 .. attempts:
    try:
      return newWebSocket(url)
    except CatchableError as error:
      if attempt == attempts:
        echo "lux-ai-player: could not connect after ", attempt,
          " attempts: ", error.msg
        return nil
      sleep(DialDelayMs)
  nil

proc run(): int =
  let
    url = socketUrl()
    registration = registrationBlob()
  echo "lux-ai-player: dialling ", url
  var redials = 0
  while redials <= ReceiveRetries:
    let socket = dial(url, if redials == 0: DialAttempts else: RedialAttempts)
    if socket == nil:
      return 0
    var
      frames = 0
      sent = 0
    try:
      socket.send(registration, BinaryMessage)
      sent = 1
      echo "lux-ai-player: registered"
      while true:
        let message = socket.receiveMessage()
        if message.isNone:
          continue
        inc frames
        ## Re-send the registration over the first ~10 s of received frames.
        if sent < RegistrationResends and frames mod 15 == 0:
          inc sent
          socket.send(registration, BinaryMessage)
        ## The Sprite v1 Ready packet. Legitimate here because this seat never
        ## sends inputs: the server computes every action.
        socket.send(blobFromSpriteReady(), BinaryMessage)
    except CatchableError as error:
      ## A dead socket is the NORMAL end of an episode.
      echo "lux-ai-player: socket closed (", error.msg, ")"
      try:
        socket.close()
      except CatchableError:
        discard
      ## EXIT 0 ON A DEAD SOCKET. whisky's `receiveMessage` RAISES on a close
      ## frame, and the game's `quit(0)` can outrun the flushed `done` frame, so
      ## a naive player exits 1 and fails certification intermittently (the raid
      ## 0.1.3 scar). Once a frame has arrived the episode was real and its end
      ## is the normal end of this process.
      if frames > 0:
        return 0
      inc redials
      sleep(DialDelayMs)
  ## Every re-dial exhausted without ever seeing a frame: still exit 0. Nothing
  ## a player container does may fail an episode the game itself completed.
  0

when isMainModule:
  quit(run())
