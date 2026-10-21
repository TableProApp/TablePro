#!/usr/bin/env python3
# Writes an sk-ssh-ed25519@openssh.com private key and its .pub without a security key attached.
# Signing with it can never work, which is the point: the cell checks the client names the key
# type before it tries. ssh-keygen -l reads it as ED25519-SK and sshd accepts the .pub.
#
# Usage: make-sk-key.py <private-key-path>

import base64
import os
import struct
import sys

KEY_TYPE = "sk-ssh-ed25519@openssh.com"
APPLICATION = "ssh:"


def string(value):
    if isinstance(value, str):
        value = value.encode()
    return struct.pack(">I", len(value)) + value


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-sk-key.py <private-key-path>")
    path = sys.argv[1]
    public_key = os.urandom(32)
    public_blob = string(KEY_TYPE) + string(public_key) + string(APPLICATION)

    check = os.urandom(4)
    flags = bytes([0x01])
    private = (
        check
        + check
        + string(KEY_TYPE)
        + string(public_key)
        + string(APPLICATION)
        + flags
        + string(os.urandom(64))
        + string(b"")
        + string("tablepro-sk")
    )
    pad = 1
    while len(private) % 8:
        private += bytes([pad])
        pad += 1

    body = (
        b"openssh-key-v1\x00"
        + string("none")
        + string("none")
        + string(b"")
        + struct.pack(">I", 1)
        + string(public_blob)
        + string(private)
    )
    encoded = base64.b64encode(body).decode()
    lines = [encoded[i : i + 70] for i in range(0, len(encoded), 70)]

    with open(path, "w", encoding="ascii") as handle:
        handle.write("-----BEGIN OPENSSH PRIVATE KEY-----\n")
        handle.write("\n".join(lines) + "\n")
        handle.write("-----END OPENSSH PRIVATE KEY-----\n")
    os.chmod(path, 0o600)
    with open(path + ".pub", "w", encoding="ascii") as handle:
        handle.write(f"{KEY_TYPE} {base64.b64encode(public_blob).decode()} tablepro-sk\n")


if __name__ == "__main__":
    main()
