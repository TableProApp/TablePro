# Answers PRELOGIN, then refuses LOGIN7 with the ERROR tokens given on the command line.
# Usage: python3 -I fake_login.py "4060:11:Cannot open database ..." "18456:14:Login failed for user 'v'."
import socket
import struct
import sys


def b_varchar(text):
    return bytes([len(text)]) + text.encode("utf-16-le")


def us_varchar(text):
    return struct.pack("<H", len(text)) + text.encode("utf-16-le")


def prelogin():
    version = bytes([16, 0, 0x07, 0xD0, 0, 0])
    enc = bytes([2])
    offset = 2 * 5 + 1
    return (struct.pack(">BHH", 0, offset, len(version))
            + struct.pack(">BHH", 1, offset + len(version), len(enc))
            + b"\xff" + version + enc)


def error(number, severity, text):
    body = (struct.pack("<iBB", number, 1, severity) + us_varchar(text)
            + b_varchar("fake") + b_varchar("") + struct.pack("<i", 1))
    return bytes([0xAA]) + struct.pack("<H", len(body)) + body


def refusal():
    out = b""
    for spec in sys.argv[1:]:
        number, severity, text = spec.split(":", 2)
        out += error(int(number), int(severity), text)
    return out + bytes([0xFD]) + struct.pack("<HHQ", 0x02, 0, 0)


def receive(conn, size):
    data = b""
    while len(data) < size:
        part = conn.recv(size - len(data))
        if not part:
            return None
        data += part
    return data


def read_message(conn):
    payload = b""
    while True:
        header = receive(conn, 8)
        if header is None:
            return None
        kind, status, length = struct.unpack(">BBH", header[:4])
        body = receive(conn, length - 8)
        if body is None:
            return None
        payload += body
        if status & 0x01:
            return kind


def packet(payload):
    return struct.pack(">BBHHBB", 0x04, 1, len(payload) + 8, 0, 1, 0) + payload


def main():
    server = socket.create_server(("127.0.0.1", 0))
    server.settimeout(20)
    print(server.getsockname()[1], flush=True)
    conn, _ = server.accept()
    conn.settimeout(20)
    with conn:
        while True:
            kind = read_message(conn)
            if kind is None:
                return
            if kind == 0x12:
                conn.sendall(packet(prelogin()))
            elif kind == 0x10:
                conn.sendall(packet(refusal()))
            else:
                return


if __name__ == "__main__":
    main()
