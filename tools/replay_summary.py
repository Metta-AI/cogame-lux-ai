#!/usr/bin/env python3
"""Print one strict-UTF-8 JSON summary of a `COWLDLUX` replay.

Python 3 stdlib only — no Nim, no Docker — so phase 60 can read a hosted replay
straight off S3:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                       # strict UTF-8: ok
    jq -r '.protocol, .results.reason, .results.cityTiles[]' /tmp/ep.json
    jq -r '[.directives[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json
    jq -r '[.directives[]|select(.note!="")]|length' /tmp/ep.json

Output shape:

    {"protocol":"lux-ai/v1","gameVersion":"1","seed":…,"mapSize":16,
     "names":[…],"aliases":[…],"policyKinds":[…],"turnCount":…,
     "directives":[…],"fallbacks":N,"results":{…}}

Everything is decoded STRICTLY: `bytes.decode("utf-8")` with no `errors=`
fallback, so a string that was truncated on a byte boundary mid-codepoint fails
here loudly instead of rendering fine in one lenient browser and nowhere else.
"""

from __future__ import annotations

import json
import struct
import sys
import zlib

MAGIC = b"COWLDLUX"
FORMAT_VERSION = 1
PROTOCOL = "lux-ai/v1"

TICK_HASH = 0x01
INPUT = 0x02
JOIN = 0x03
LEAVE = 0x04
CHAT = 0x05
DEBUG_SPRITE = 0x06

REPLAY_FPS = 15


class Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.at = 0

    def take(self, count: int) -> bytes:
        if self.at + count > len(self.data):
            raise ValueError("replay is truncated at byte %d" % self.at)
        chunk = self.data[self.at:self.at + count]
        self.at += count
        return chunk

    def u8(self) -> int:
        return self.take(1)[0]

    def u16(self) -> int:
        return struct.unpack("<H", self.take(2))[0]

    def i16(self) -> int:
        return struct.unpack("<h", self.take(2))[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def string(self) -> str:
        # STRICT: no errors= fallback. A byte-truncated codepoint dies here.
        return self.take(self.u16()).decode("utf-8")

    def blob(self) -> bytes:
        return self.take(self.u32())


def decompress_if_needed(data: bytes) -> bytes:
    if data.startswith(MAGIC):
        return data
    if len(data) > 18 and data[0] == 0x1F and data[1] == 0x8B:
        return zlib.decompress(data, 16 + zlib.MAX_WBITS)
    if len(data) > 6 and (data[0] & 0x0F) == 8:
        try:
            return zlib.decompress(data)
        except zlib.error:
            pass
    return data


def brace_match(text: str) -> str:
    """The config JSON, brace-matched from the first `{`."""
    start = text.index("{")
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise ValueError("config JSON never closed")


def summarise(raw: bytes) -> dict:
    data = decompress_if_needed(raw)
    reader = Reader(data)
    if reader.take(len(MAGIC)) != MAGIC:
        raise ValueError("replay magic is not %s" % MAGIC.decode())
    version = reader.u16()
    if version != FORMAT_VERSION:
        raise ValueError("unsupported replay format version %d" % version)
    game_name = reader.string()
    game_version = reader.string()
    reader.u64()                                   # recorded-at, milliseconds
    config_text = reader.string()
    config = json.loads(brace_match(config_text))

    joins: list[dict] = []
    chats: list[dict] = []
    input_bytes: dict[tuple[int, int], list[int]] = {}
    max_tick = 0

    while reader.at < len(data):
        kind = reader.u8()
        if kind == TICK_HASH:
            tick = reader.u32()
            reader.u64()
            max_tick = max(max_tick, tick)
        elif kind == INPUT:
            time = reader.u32()
            player = reader.u8()
            key = reader.u8()
            tick = round(time * REPLAY_FPS / 1000)
            input_bytes.setdefault((tick, player), []).append(key)
        elif kind == JOIN:
            reader.u32()
            player = reader.u8()
            name = reader.string()
            slot = reader.i16()
            token = reader.string()
            joins.append({"player": player, "name": name, "slot": slot,
                          "token_len": len(token)})
        elif kind == LEAVE:
            reader.u32()
            reader.u8()
        elif kind == CHAT:
            reader.u32()
            reader.u8()
            chats.append({"message": reader.string()})
        elif kind == DEBUG_SPRITE:
            reader.u32()
            reader.u8()
            reader.blob()
        else:
            raise ValueError("unknown replay record type %d" % kind)

    directives: list[dict] = []
    fallbacks = 0
    results: dict = {}
    registrations: list[dict] = []
    stop: dict | None = None
    for chat in chats:
        message = chat["message"]
        if not message.startswith("{"):
            continue
        try:
            node = json.loads(message)
        except ValueError:
            continue
        kind = node.get("k")
        if kind == "directive":
            directives.append({
                "turn": node.get("turn"),
                "seat": node.get("seat"),
                "alias": node.get("alias", ""),
                "source": node.get("source", ""),
                "latency_ms": node.get("latency_ms", 0),
                "stance": node.get("stance", ""),
                "research": node.get("research", ""),
                "note": node.get("note", ""),
            })
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "result":
            results = node.get("results", {})
        elif kind == "register":
            registrations.append({"seat": node.get("seat"),
                                  "policy": node.get("policy", ""),
                                  "kind": node.get("kind", "")})
        elif kind == "stop":
            stop = {"turn": node.get("turn"), "endRule": node.get("endRule")}

    names = [player.get("name", "") for player in config.get("players", [])]
    if joins:
        by_slot = {join["player"]: join["name"] for join in joins}
        names = [by_slot.get(i, names[i] if i < len(names) else "")
                 for i in range(max(2, len(names)))]
    return {
        "protocol": PROTOCOL,
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "mapSize": config.get("mapSize"),
        "maxTurns": config.get("maxTurns"),
        "names": names,
        "aliases": results.get("aliases", ["RED-alpha", "BLUE-alpha"]),
        "policyKinds": results.get(
            "policyKinds",
            [registration["kind"] for registration in registrations] or
            ["scripted", "scripted"]),
        "registrations": registrations,
        "turnCount": results.get("turnsPlayed", 0),
        "tickCount": max_tick + 1,
        "directiveRecords": len(input_bytes),
        "directives": directives,
        "fallbacks": fallbacks,
        "stop": stop,
        "results": results,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: replay_summary.py <path.replay>\n")
        return 2
    with open(argv[1], "rb") as handle:
        summary = summarise(handle.read())
    # ensure_ascii=False so the output really is UTF-8 and a lone surrogate
    # would be caught by the encode below rather than smuggled through as \\u.
    sys.stdout.buffer.write(
        json.dumps(summary, ensure_ascii=False).encode("utf-8") + b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
