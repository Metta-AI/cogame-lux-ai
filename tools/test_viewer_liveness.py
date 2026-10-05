"""Probe real viewer sockets while the simulation waits in lobby or shutdown."""

import base64
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
from typing import TextIO, cast


def read_exact(stream, length):
    data = bytearray()
    while len(data) < length:
        chunk = stream.read(length - len(data))
        assert chunk, "viewer closed before its initial frame"
        data.extend(chunk)
    return bytes(data)


def probe(port, path):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall(
            (
                f"GET {path} HTTP/1.1\r\nHost: localhost\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        with sock.makefile("rb") as stream:
            assert b"101" in stream.readline()
            while stream.readline() != b"\r\n":
                pass
            opcode, size = read_exact(stream, 2)
            assert opcode == 0x82, "expected a binary viewer frame"
            assert not size & 0x80, "server frames must be unmasked"
            if size == 126:
                size = struct.unpack("!H", read_exact(stream, 2))[0]
            elif size == 127:
                size = struct.unpack("!Q", read_exact(stream, 8))[0]
            frame = read_exact(stream, size)
            assert b"island" in frame, "initial frame lacks board sprite definitions"
            assert b'"ph"' in frame, "initial frame lacks broadcast state"
            print(f"{path}: complete initial frame ({len(frame)} bytes)")


def main():
    binary = str(Path(sys.argv[1]).resolve())
    for phase in ("lobby", "shutdown"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            config = root / "config.json"
            config.write_text(
                json.dumps(
                    {
                        "fastMode": True,
                        "maxTurns": 1,
                        "lobbyJoinTimeoutTicks": 2400 if phase == "lobby" else 1,
                    }
                )
            )
            results = root / "results.json"
            env = {
                **os.environ,
                "COGAME_PORT": str(port),
                "COGAME_CONFIG_URI": config.as_uri(),
                "COGAME_RESULTS_URI": results.as_uri(),
            }
            with subprocess.Popen(
                [binary],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            ) as process:
                try:
                    for line in cast(TextIO, process.stdout):
                        if "listening on" in line:
                            break
                    assert process.poll() is None, "game failed to start"
                    if phase == "shutdown":
                        deadline = time.monotonic() + 10
                        while not results.exists():
                            assert process.poll() is None, "game exited without results"
                            assert time.monotonic() < deadline, "game never settled"
                            time.sleep(0.01)
                    print(phase)
                    probe(port, "/global")
                    probe(port, "/replay")
                finally:
                    process.terminate()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
