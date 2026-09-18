#!/usr/bin/env python3
"""Re-verify, against a live broker, the Kafka wire-format facts Plugins/KafkaDriverPlugin/
hard-codes. Run through scripts/check-kafka-protocol.sh.

Every check here corresponds to a decision in the Swift codec that cannot be derived from the
surrounding format, and that fails silently when it is wrong: a malformed request makes the
broker consume what it can and close the socket, with no error response at all.

This client is deliberately hand-written and shares no code with the plugin. Two independent
implementations agreeing against a real broker is the point; importing the plugin's own
assumptions would make the check vacuous.
"""
import socket
import struct
import sys

FAILURES = []
CHECKS = 0


def check(name, condition, detail=""):
    global CHECKS
    CHECKS += 1
    if condition:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}" + (f"\n          {detail}" if detail else ""))
        FAILURES.append(name)


# ---------------------------------------------------------------- wire primitives

def uvarint(buf, i):
    result, shift = 0, 0
    while True:
        byte = buf[i]
        i += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, i
        shift += 7


def zigzag(buf, i):
    raw, i = uvarint(buf, i)
    return (raw >> 1) ^ -(raw & 1), i


def compact_string(buf, i):
    n, i = uvarint(buf, i)
    if n == 0:
        return None, i
    return buf[i:i + n - 1].decode(), i + n - 1


def write_compact_string(value):
    encoded = value.encode()
    return bytes([len(encoded) + 1]) + encoded


def skip_tags(buf, i):
    count, i = uvarint(buf, i)
    for _ in range(count):
        _, i = uvarint(buf, i)
        size, i = uvarint(buf, i)
        i += size
    return i


class Broker:
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.correlation = 0

    def close(self):
        self.sock.close()

    def _recv(self, count):
        buf = b""
        while len(buf) < count:
            chunk = self.sock.recv(count - len(buf))
            if not chunk:
                raise EOFError("broker closed the connection: the request was malformed")
            buf += chunk
        return buf

    def send(self, api_key, version, body, flexible_header=True):
        self.correlation += 1
        header = struct.pack(">hhi", api_key, version, self.correlation)
        # client_id is flexibleVersions "none": a legacy int16-length string even in a
        # flexible header.
        header += struct.pack(">h", 8) + b"tp-probe"
        if flexible_header:
            header += b"\x00"
        payload = header + body
        self.sock.sendall(struct.pack(">i", len(payload)) + payload)
        return self._recv(struct.unpack(">i", self._recv(4))[0])


# ---------------------------------------------------------------- checks

def check_api_versions(broker):
    """ApiVersions v3 sends a FLEXIBLE request header but the response header is v0, with no
    tagged fields, at every version (KIP-511; Kafka's generator hard-codes apiKey == 18).
    Parsing a tag buffer here shifts the error code and every byte after it."""
    body = write_compact_string("tp-probe") + write_compact_string("0.1") + b"\x00"
    resp = broker.send(18, 3, body)

    i = 4
    error_no_tags = struct.unpack(">h", resp[i:i + 2])[0]
    # What the wrong reading produces, kept so the failure message can name it.
    error_with_tags = struct.unpack(">h", resp[skip_tags(resp, i):skip_tags(resp, i) + 2])[0]
    check(
        "ApiVersions response header carries no tagged fields",
        error_no_tags == 0,
        f"error parsed as {error_no_tags} without a tag buffer, {error_with_tags} with one",
    )

    i += 2
    count, i = uvarint(resp, i)
    apis = {}
    for _ in range(count - 1):
        key, low, high = struct.unpack(">hhh", resp[i:i + 6])
        i = skip_tags(resp, i + 6)
        apis[key] = (low, high)
    return apis


def check_version_floor(apis):
    """The plugin negotiates against the broker's advertised range instead of hardcoding a
    version, because Kafka 4.x removed the oldest version of several APIs."""
    # api key -> (name, the version the plugin tops out at)
    ceilings = {
        0: ("Produce", 9), 1: ("Fetch", 12), 2: ("ListOffsets", 7), 3: ("Metadata", 12),
        9: ("OffsetFetch", 8), 10: ("FindCoordinator", 4), 15: ("DescribeGroups", 5),
        16: ("ListGroups", 4), 17: ("SaslHandshake", 1), 36: ("SaslAuthenticate", 2),
    }
    for key, (name, ceiling) in ceilings.items():
        if key not in apis:
            check(f"{name} is offered by the broker", False, "the broker does not advertise it")
            continue
        low, high = apis[key]
        check(
            f"{name} v{ceiling} is inside the broker's v{low}..v{high}",
            low <= ceiling <= high,
            f"the plugin's ceiling v{ceiling} is outside what this broker accepts",
        )


def check_metadata_shape(broker):
    """Two traps in one request. A COMPACT null array is uvarint 0, not the legacy 0xff: 0xff
    sets the varint continuation bit and the broker eats the bytes that follow. And Metadata
    v11 REMOVED include_cluster_authorized_operations, so v12 carries two trailing booleans
    where v8..v10 carry three."""
    body = b"\x00" + b"\x00" + b"\x00" + b"\x00"   # topics=null; 2 bools; tags
    try:
        resp = broker.send(3, 12, body)
    except EOFError as error:
        check("Metadata v12 takes a compact null array and two booleans", False, str(error))
        return None
    i = skip_tags(resp, 4)
    i += 4                                          # throttle_time_ms
    count, i = uvarint(resp, i)
    brokers = []
    for _ in range(count - 1):
        node = struct.unpack(">i", resp[i:i + 4])[0]
        host, i = compact_string(resp, i + 4)
        port = struct.unpack(">i", resp[i:i + 4])[0]
        _rack, i = compact_string(resp, i + 4)
        i = skip_tags(resp, i)
        brokers.append((node, host, port))
    check("Metadata v12 takes a compact null array and two booleans", bool(brokers),
          "the reply parsed but named no brokers")
    return brokers


def check_legacy_null_array_is_rejected(host, port):
    """The negative half of the check above, and the one that actually bites.

    In COMPACT encoding a null array is uvarint 0. The legacy form is -1 as an int32, and
    writing its first byte (0xff) here sets the varint continuation bit: the broker keeps
    consuming the bytes that follow as part of the length and then hangs up. A client that
    reaches for the legacy null gets a dropped socket and no error, so this asserts the
    broker really does refuse it rather than tolerating it."""
    probe = Broker(host, port)
    try:
        probe.send(3, 12, b"\xff" + b"\x00" + b"\x00" + b"\x00")
        check("A legacy 0xff null array is refused at Metadata v12", False,
              "the broker accepted it, so the compact-null rule may have changed")
    except EOFError:
        check("A legacy 0xff null array is refused at Metadata v12", True)
    finally:
        probe.close()


def check_fetch_is_name_based_through_v12(broker, topic):
    """Fetch v13+ (KIP-516) replaced the topic NAME with a 16-byte topic UUID. v12 is the
    highest name-based version, which is why the plugin's ceiling is v12 and not the
    broker's maximum."""
    def fetch(version):
        body = struct.pack(">iiii", -1, 200, 1, 1_048_576) + b"\x01"
        body += struct.pack(">ii", 0, 0)
        body += b"\x02" + write_compact_string(topic) + b"\x02"
        body += struct.pack(">ii", 0, -1) + struct.pack(">q", 0) + struct.pack(">i", -1)
        body += struct.pack(">q", -1) + struct.pack(">i", 1_048_576) + b"\x00"
        body += b"\x00" + b"\x01" + write_compact_string("") + b"\x00"
        return broker.send(1, version, body)

    try:
        fetch(12)
        check("Fetch v12 still addresses a topic by name", True)
    except EOFError as error:
        check("Fetch v12 still addresses a topic by name", False, str(error))


def check_produce_crc(broker, apis):
    """The broker rejects a batch whose CRC-32C does not match, so this proves the plugin's
    hand-rolled Castagnoli table against the broker's own."""
    if 0 not in apis:
        check("Produce accepts a batch with a hand-computed CRC-32C", False, "no Produce API")
        return

    table = []
    for index in range(256):
        value = index
        for _ in range(8):
            value = (value >> 1) ^ 0x82F63B78 if value & 1 else value >> 1
        table.append(value)

    def crc32c(data):
        crc = 0xFFFFFFFF
        for byte in data:
            crc = (crc >> 8) ^ table[(crc ^ byte) & 0xFF]
        return crc ^ 0xFFFFFFFF

    key, value = b"probe-key", b"probe-value"
    # One v2 record: attributes, timestampDelta, offsetDelta, then zig-zag-prefixed key and
    # value and an empty header array. Small values encode to one zig-zag byte each.
    inner = b"\x00" + b"\x00" + b"\x00" \
        + bytes([len(key) << 1]) + key \
        + bytes([len(value) << 1]) + value \
        + b"\x00"
    framed = bytes([len(inner) << 1]) + inner

    # From attributes to the end: exactly the range the CRC covers.
    body = struct.pack(">h", 0) + struct.pack(">i", 0) + struct.pack(">q", 0) \
        + struct.pack(">q", 0) + struct.pack(">q", -1) + struct.pack(">h", -1) \
        + struct.pack(">i", -1) + struct.pack(">i", 1) + framed
    after = struct.pack(">i", -1) + b"\x02" + struct.pack(">I", crc32c(body)) + body
    batch = struct.pack(">q", 0) + struct.pack(">i", len(after)) + after

    request = b"\x00"                                            # transactionalId = null
    request += struct.pack(">hi", -1, 30_000)
    request += b"\x02" + write_compact_string("tp-probe-crc") + b"\x02"
    request += struct.pack(">i", 0)
    encoded_length, remaining = b"", len(batch) + 1
    while remaining >= 0x80:
        encoded_length += bytes([(remaining & 0x7F) | 0x80])
        remaining >>= 7
    request += encoded_length + bytes([remaining])
    request += batch + b"\x00" + b"\x00" + b"\x00"

    try:
        resp = broker.send(0, 9, request)
    except EOFError as error:
        check("Produce accepts a batch with a hand-computed CRC-32C", False, str(error))
        return
    i = skip_tags(resp, 4)
    count, i = uvarint(resp, i)
    if count < 2:
        check("Produce accepts a batch with a hand-computed CRC-32C", False, "empty response")
        return
    _name, i = compact_string(resp, i)
    pcount, i = uvarint(resp, i)
    _index = struct.unpack(">i", resp[i:i + 4])[0]
    error_code = struct.unpack(">h", resp[i + 4:i + 6])[0]
    # 2 is CORRUPT_MESSAGE, which is what a wrong CRC produces.
    check(
        "Produce accepts a batch with a hand-computed CRC-32C",
        error_code != 2,
        f"the broker answered error {error_code}; 2 means the CRC did not match",
    )


def check_sasl_handshake_is_never_flexible(apis):
    """SaslHandshake is declared flexibleVersions "none" at BOTH v0 and v1, unlike the APIs
    on either side of it. Encoding it compactly is an authentication failure that reads like
    a wrong password, so the plugin must keep it legacy."""
    check(
        "SaslHandshake exists and tops out at v1",
        apis.get(17, (0, 0))[1] == 1,
        f"the broker advertises SaslHandshake {apis.get(17)}; the plugin assumes v0..v1",
    )


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9092
    print(f"Kafka wire-format checks against {host}:{port}\n")

    try:
        broker = Broker(host, port)
    except OSError as error:
        print(f"Could not reach a broker at {host}:{port}: {error}")
        print("Start one with the docker command in scripts/check-kafka-protocol.sh.")
        return 2

    try:
        apis = check_api_versions(broker)
        check_version_floor(apis)
        check_sasl_handshake_is_never_flexible(apis)
        brokers = check_metadata_shape(broker)
        if brokers:
            print(f"        broker(s): {', '.join(f'{n}@{h}:{p}' for n, h, p in brokers)}")
        check_fetch_is_name_based_through_v12(broker, "tp-probe-crc")
        check_produce_crc(broker, apis)
    finally:
        broker.close()

    check_legacy_null_array_is_rejected(host, port)

    print()
    if FAILURES:
        print(f"{len(FAILURES)} of {CHECKS} checks failed: {', '.join(FAILURES)}")
        print("Plugins/KafkaDriverPlugin/ encodes one of these assumptions and it no longer holds.")
        return 1
    print(f"All {CHECKS} checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
