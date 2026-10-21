# One loopback MySQL session for check-mariadb-tls-modes.sh and check-mysql-dump-plaintext-password.sh. Prints the
# port, then a JSON line saying whether TLS came up, whether the login and the answer to the --auth request arrived,
# and whether the secret crossed in plaintext.
import argparse
import json
import socket
import ssl
import struct
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--cert")
parser.add_argument("--key")
# dialog is how PAM asks; sha2-full is caching_sha2_password asking for full authentication, which a client
# answers with the typed password once it thinks the session is secure.
parser.add_argument("--auth", choices=["cleartext", "dialog", "sha2-full"])
parser.add_argument("--secret", default="")
args = parser.parse_args()

capabilities = 0x1 | 0x8 | 0x200 | 0x2000 | 0x8000 | 0x20000 | 0x80000
if args.cert:
    capabilities |= 0x800

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(1)
print(listener.getsockname()[1], flush=True)
listener.settimeout(20)
connection, _ = listener.accept()
connection.settimeout(10)

plaintext = bytearray()
state = {"askedForTLS": False, "encrypted": False, "sawLogin": False, "answer": None, "loggedIn": False}
stream = connection


def receive(count):
    data = bytearray()
    while len(data) < count:
        chunk = stream.recv(count - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    if not state["encrypted"]:
        plaintext.extend(data)
    return bytes(data)


def read_packet():
    header = receive(4)
    length = header[0] | header[1] << 8 | header[2] << 16
    return header[3], receive(length) if length else b""


def send(payload, sequence):
    stream.sendall(struct.pack("<I", len(payload))[:3] + bytes([sequence]) + payload)


handshake = bytes([10]) + b"8.0.36\0" + bytes([1, 0, 0, 0]) + b"abcdefgh\0"
handshake += bytes([capabilities & 0xFF, (capabilities >> 8) & 0xFF, 45, 2, 0])
handshake += bytes([(capabilities >> 16) & 0xFF, (capabilities >> 24) & 0xFF, 21]) + bytes(10)
handshake += b"ijklmnopqrst\0mysql_native_password\0"
ok = bytes([0, 0, 0, 2, 0, 0, 0])

try:
    send(handshake, 0)
    sequence, login = read_packet()
    if args.cert and len(login) == 32:
        state["askedForTLS"] = True
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        stream = context.wrap_socket(connection, server_side=True)
        state["encrypted"] = True
        sequence, login = read_packet()
    state["sawLogin"] = True
    if args.auth == "cleartext":
        send(b"\xfemysql_clear_password\0", (sequence + 1) & 0xFF)
        sequence, answer = read_packet()
        state["answer"] = answer.split(b"\0")[0].decode(errors="replace")
    elif args.auth == "dialog":
        send(b"\xfedialog\0\x05Password: ", (sequence + 1) & 0xFF)
        sequence, answer = read_packet()
        state["answer"] = answer.split(b"\0")[0].decode(errors="replace")
    elif args.auth == "sha2-full":
        send(b"\xfecaching_sha2_password\0abcdefghijklmnopqrst\0", (sequence + 1) & 0xFF)
        sequence, _ = read_packet()
        send(b"\x01\x04", (sequence + 1) & 0xFF)
        sequence, answer = read_packet()
        # 0x02 asks for the server's RSA key, which is how a client that knows it is in plaintext answers.
        state["answer"] = "public key request" if answer == b"\x02" else answer.split(b"\0")[0].decode(errors="replace")
        raise EOFError
    send(ok, (sequence + 1) & 0xFF)
    state["loggedIn"] = True
    while True:
        sequence, command = read_packet()
        if command[:1] == b"\x01":
            break
        send(ok, (sequence + 1) & 0xFF)
except (EOFError, OSError, ssl.SSLError):
    pass

state["secretInPlaintext"] = bool(args.secret) and args.secret.encode() in plaintext
print(json.dumps(state), flush=True)
sys.exit(0)
