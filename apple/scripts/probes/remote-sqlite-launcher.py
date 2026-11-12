#!/usr/bin/env python3
"""Probe the remote SQLite launcher: exec-request size and a HELLO -> READY round-trip.

Why this exists: the agent program is delivered inline on the SSH exec request, and libssh2
rejects an uncompressed packet payload at or above MAX_SSH_PACKET_LEN - 0x100 = 34744 with
LIBSSH2_ERROR_INVAL (-34). RemoteSQLiteAgentSource compresses the program (Apple
COMPRESSION_ZLIB, raw DEFLATE) and carries it once. This mirrors that on the CLI: raw DEFLATE
built with wbits -15, decompressed with the production bootstrap, run against the local python3.

Run from the repo root:  python3 apple/scripts/probes/remote-sqlite-launcher.py
"""
import base64
import re
import struct
import subprocess
import sys
import zlib
from pathlib import Path

LIMIT = 35000 - 0x100  # MAX_SSH_PACKET_LEN - 0x100, libssh2 src/transport.c
INTERPRETERS = ["python3", "/usr/bin/python3", "/usr/libexec/platform-python"]
BOOTSTRAP = "import base64,zlib,sys;exec(zlib.decompress(base64.b64decode(sys.argv[1]),-15))"
NOTICE = "TPRSQL:NO_PYTHON"
SOURCE = Path(__file__).resolve().parents[2] / "TablePro/Core/RemoteSQLite/RemoteSQLiteAgentSource.swift"


def agent_program() -> bytes:
    text = SOURCE.read_text(encoding="utf-8")
    match = re.search(r'static let python = #"""\n(.*)\n"""#', text, re.S)
    if not match:
        sys.exit("could not extract the agent program from " + str(SOURCE))
    return (match.group(1) + "\n").encode("utf-8")


def raw_deflate(data: bytes) -> bytes:
    comp = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
    return comp.compress(data) + comp.flush()


def launcher_command(program: bytes) -> str:
    blob = base64.b64encode(raw_deflate(program)).decode()
    branches = "; ".join(
        f'if command -v "{i}" >/dev/null 2>&1; then exec "{i}" -I -S -c "{BOOTSTRAP}" "$b"; fi'
        for i in INTERPRETERS
    )
    return "sh -c 'b=" + blob + "; " + branches + "; echo " + NOTICE + "; exit 0'"


def frame(op: int, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload) + 1) + bytes([op]) + payload


def read_str(body: bytes, off: int):
    n = struct.unpack(">I", body[off:off + 4])[0]
    return body[off + 4:off + 4 + n].decode(), off + 4 + n


def main() -> int:
    program = agent_program()
    command = launcher_command(program)
    size = len(command.encode("utf-8"))
    print(f"program {len(program)} B -> exec request {size} B (limit {LIMIT}, headroom {LIMIT - size})")
    if size >= LIMIT:
        print("FAIL: exec request would be rejected by libssh2")
        return 1

    path = b":memory:"
    hello = frame(0x01, struct.pack(">I", 1) + struct.pack(">I", len(path)) + path + struct.pack(">I", 0))
    result = subprocess.run(command, shell=True, input=hello, capture_output=True, timeout=30)
    out = result.stdout
    if len(out) < 5:
        print("FAIL: no reply. stderr:", result.stderr.decode(errors="replace")[:400])
        return 1
    op = out[4]
    body = out[5:4 + struct.unpack(">I", out[:4])[0]]
    if op != 0x81:  # OP_READY
        print(f"FAIL: expected OP_READY, got 0x{op:02x} {body[:80]!r}")
        return 1
    version = struct.unpack(">I", body[:4])[0]
    sqlite_version, off = read_str(body, 4)
    python_version, _ = read_str(body, off)
    print(f"PASS: OP_READY proto={version} sqlite={sqlite_version} python={python_version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
