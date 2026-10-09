# A scripted TDS 7.4 server for check-freetds-cell-reading.sh. It serves one client in the clear and answers
# each SQL batch with a fixed token stream, so db-lib's reading of those exact bytes can be checked without
# SQL Server. Layouts follow MS-TDS 2.2.5 (data types) and 2.2.7 (tokens).
#
# Usage: python3 -I fake_tds.py   (prints the port it listens on, then serves one connection)

import datetime
import socket
import struct

COLLATION = bytes([0x09, 0x04, 0xD0, 0x00, 0x34])
DONE, DONEPROC, DONEINPROC = 0xFD, 0xFE, 0xFF
DONE_MORE, DONE_COUNT, DONE_ATTN = 0x01, 0x10, 0x20
CMD_UPDATE, CMD_EXECUTE = 0xC5, 0xE0
NULLABLE = 0x0001


def b_varchar(text):
    return bytes([len(text)]) + text.encode("utf-16-le")


def us_varchar(text):
    return struct.pack("<H", len(text)) + text.encode("utf-16-le")


def token(kind, body):
    return bytes([kind]) + struct.pack("<H", len(body)) + body


def done(kind, status, curcmd=0, count=0):
    return bytes([kind]) + struct.pack("<HHQ", status, curcmd, count)


def return_status(value):
    return b"\x79" + struct.pack("<i", value)


def prelogin():
    version = bytes([16, 0, 0x07, 0xD0, 0, 0])
    encryption_not_supported = bytes([2])
    offset = 2 * 5 + 1
    return (struct.pack(">BHH", 0, offset, len(version))
            + struct.pack(">BHH", 1, offset + len(version), len(encryption_not_supported))
            + b"\xff" + version + encryption_not_supported)


def login_ack():
    packet_size = token(0xE3, bytes([4]) + b_varchar("4096") + b_varchar("4096"))
    ack = token(0xAD, bytes([1, 0x74, 0, 0, 4]) + b_varchar("fake_tds") + bytes([16, 0, 0, 0]))
    return packet_size + ack + done(DONE, 0)


def columns(*specs):
    meta = b"".join(struct.pack("<IH", 0, NULLABLE) + type_info + b_varchar(name) for name, type_info in specs)
    return b"\x81" + struct.pack("<H", len(specs)) + meta


def short_len(data):
    return b"\xff\xff" if data is None else struct.pack("<H", len(data)) + data


def plp(data):
    if data is None:
        return b"\xff" * 8
    chunk = struct.pack("<I", len(data)) + data if data else b""
    return struct.pack("<Q", len(data)) + chunk + struct.pack("<I", 0)


def text_ptr(data):
    if data is None:
        return b"\x00"
    return bytes([16]) + b"\x01" * 16 + b"\x00" * 8 + struct.pack("<i", len(data)) + data


# text and image carry the table they come from in their type info.
TABLE_NAME = bytes([1]) + us_varchar("t")
CELL_TYPES = [
    ("varchar(20)", b"\xa7" + struct.pack("<H", 20) + COLLATION, short_len),
    ("nvarchar(20)", b"\xe7" + struct.pack("<H", 40) + COLLATION, short_len),
    ("nvarchar(max)", b"\xe7\xff\xff" + COLLATION, plp),
    ("text", b"\x23" + struct.pack("<i", 2**31 - 1) + COLLATION + TABLE_NAME, text_ptr),
    ("varbinary(20)", b"\xa5" + struct.pack("<H", 20), short_len),
    ("image", b"\x22" + struct.pack("<i", 2**31 - 1) + TABLE_NAME, text_ptr),
]


def null_vs_empty():
    specs, values = [], b""
    for name, type_info, encode in CELL_TYPES:
        specs += [(name + " empty", type_info), (name + " NULL", type_info)]
        values += encode(b"") + encode(None)
    return columns(*specs) + b"\xd1" + values + done(DONE, DONE_COUNT, count=1)


# The time is UTC, counted in units of 10^-scale seconds; the offset is minutes east of UTC.
def datetimeoffset(local, fraction, scale, offset_minutes):
    utc = local - datetime.timedelta(minutes=offset_minutes)
    ticks = (utc.hour * 3600 + utc.minute * 60 + utc.second) * 10**scale + fraction
    size = 3 if scale <= 2 else 4 if scale <= 4 else 5
    value = (ticks.to_bytes(size, "little") + (utc.toordinal() - 1).to_bytes(3, "little")
             + struct.pack("<h", offset_minutes))
    return bytes([len(value)]) + value


def datetimeoffsets():
    meta = columns(("+05:30", bytes([0x2B, 7])), ("-08:00", bytes([0x2B, 0])))
    row = (datetimeoffset(datetime.datetime(2024, 1, 2, 3, 4, 5), 1234567, 7, 330)
           + datetimeoffset(datetime.datetime(2024, 1, 2, 20, 4, 5), 0, 0, -480))
    return meta + b"\xd1" + row + done(DONE, DONE_COUNT, count=1)


# What sp_executesql answers for a keyless UPDATE that matched one row. The UPDATE's DONEINPROC carries a count
# of 1 in both; only its DONE_COUNT bit, which SET NOCOUNT ON clears, differs.
def write_with_set_prefix():
    return (done(DONEINPROC, DONE_MORE)
            + done(DONEINPROC, DONE_MORE | DONE_COUNT, CMD_UPDATE, 1)
            + return_status(0) + done(DONEPROC, 0, CMD_EXECUTE))


def write_under_nocount():
    return done(DONEINPROC, DONE_MORE, CMD_UPDATE, 1) + return_status(0) + done(DONEPROC, 0, CMD_EXECUTE)


BATCHES = {
    "null-vs-empty": null_vs_empty,
    "datetimeoffset": datetimeoffsets,
    "count set-prefix": write_with_set_prefix,
    "count nocount-on": write_under_nocount,
}


def read_message(conn):
    kind, payload = None, b""
    while True:
        header = receive(conn, 8)
        if header is None:
            return None, None
        kind, status, length = struct.unpack(">BBH", header[:4])
        body = receive(conn, length - 8)
        if body is None:
            return None, None
        payload += body
        if status & 0x01:
            return kind, payload


def receive(conn, size):
    data = b""
    while len(data) < size:
        part = conn.recv(size - len(data))
        if not part:
            return None
        data += part
    return data


def packets(payload, size=4096):
    chunks = [payload[i:i + size - 8] for i in range(0, len(payload), size - 8)] or [b""]
    return b"".join(struct.pack(">BBHHBB", 0x04, int(n == len(chunks) - 1), len(chunk) + 8, 0, n + 1, 0) + chunk
                    for n, chunk in enumerate(chunks))


def reply(kind, payload):
    if kind == 0x12:
        return prelogin()
    if kind == 0x10:
        return login_ack()
    if kind == 0x01:
        headers_length = struct.unpack("<I", payload[:4])[0]
        batch = BATCHES.get(payload[headers_length:].decode("utf-16-le"))
        return batch() if batch else done(DONE, 0)
    if kind == 0x06:
        return done(DONE, DONE_ATTN)
    return done(DONE, 0)


def main():
    server = socket.create_server(("127.0.0.1", 0))
    server.settimeout(30)
    print(server.getsockname()[1], flush=True)
    conn, _ = server.accept()
    conn.settimeout(30)
    with conn:
        while True:
            kind, payload = read_message(conn)
            if kind is None:
                return
            conn.sendall(packets(reply(kind, payload)))


if __name__ == "__main__":
    main()
