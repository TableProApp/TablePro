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
    version, because Kafka 4.x removed the oldest version of several APIs.

    So the check is that a version can be AGREED, not that the plugin's ceiling is one the
    broker offers. KafkaApiVersionTable.negotiated takes min(broker high, our ceiling) and only
    fails when that lands below our floor, which is the whole point of negotiating down. Testing
    the ceiling for membership instead reported five failures against any broker older than the
    newest, and a real regression is then indistinguishable from that noise."""
    # api key -> (name, the plugin's floor, the plugin's ceiling)
    bounds = {
        0: ("Produce", 3, 9), 1: ("Fetch", 4, 12), 2: ("ListOffsets", 1, 7),
        3: ("Metadata", 1, 12), 9: ("OffsetFetch", 1, 8), 10: ("FindCoordinator", 0, 4),
        15: ("DescribeGroups", 0, 5), 16: ("ListGroups", 0, 4), 17: ("SaslHandshake", 0, 1),
        36: ("SaslAuthenticate", 0, 2), 20: ("DeleteTopics", 1, 5),
    }
    for key, (name, floor, ceiling) in bounds.items():
        if key not in apis:
            check(f"{name} is offered by the broker", False, "the broker does not advertise it")
            continue
        low, high = apis[key]
        agreed = min(high, ceiling)
        check(
            f"{name} negotiates to v{agreed} inside the broker's v{low}..v{high}",
            agreed >= low and agreed >= floor,
            f"the plugin speaks v{floor}..v{ceiling} and this broker speaks v{low}..v{high}",
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


def check_find_coordinator_field_order(broker, apis, brokers):
    """FindCoordinator moved its error code at v4 and the two orders are not distinguishable
    from a successful parse alone.

    Up to v3 the body opens with the error and then names the node. v4 (KIP-699) made the
    request batched and put the error at the END of each coordinator entry, after the address.
    Reading v4 in the v3 order takes the key's length prefix for an error code and a slice of
    the host for a node id, so it yields a plausible broker rather than a parse failure. Both
    orders are asserted here because both are hand-coded in KafkaFindCoordinatorRequest.

    What is asserted is the FIELD ORDER, not that a coordinator exists. A cluster where no group
    has ever committed has no __consumer_offsets topic yet and answers 15
    COORDINATOR_NOT_AVAILABLE with node -1, which is correct and which the driver retries. The
    discriminating evidence is that the key echoes back and the reply is consumed exactly."""
    available = (0, 15)
    known = {node for node, _, _ in brokers} if brokers else set()
    high = apis.get(10, (0, 0))[1]

    if high >= 4:
        body = struct.pack(">b", 0) + b"\x02" + write_compact_string("tp-probe-group") + b"\x00"
        resp = broker.send(10, 4, body)
        i = skip_tags(resp, 4) + 4                       # header tags, throttle_time_ms
        count, i = uvarint(resp, i)
        key, i = compact_string(resp, i)
        node_id = struct.unpack(">i", resp[i:i + 4])[0]
        i += 4
        host, i = compact_string(resp, i)
        i += 4                                           # port
        error_code = struct.unpack(">h", resp[i:i + 2])[0]
        i += 2
        _, i = compact_string(resp, i)                   # error_message
        i = skip_tags(resp, i)
        i = skip_tags(resp, i)
        addressed = error_code != 0 or not known or node_id in known
        check(
            "FindCoordinator v4 names the coordinator before its error code",
            count == 2 and key == "tp-probe-group" and error_code in available
            and addressed and i == len(resp),
            f"key={key} node={node_id} host={host} error={error_code}, "
            f"consumed {i} of {len(resp)} bytes",
        )

    if high >= 3:
        body = write_compact_string("tp-probe-group") + struct.pack(">b", 0) + b"\x00"
        resp = broker.send(10, 3, body)
        i = skip_tags(resp, 4) + 4
        error_code = struct.unpack(">h", resp[i:i + 2])[0]
        i += 2
        _, i = compact_string(resp, i)                   # error_message
        node_id = struct.unpack(">i", resp[i:i + 4])[0]
        i += 4
        _, i = compact_string(resp, i)                   # host
        i += 4                                           # port
        i = skip_tags(resp, i)
        addressed = error_code != 0 or not known or node_id in known
        check(
            "FindCoordinator v3 answers with its error code first",
            error_code in available and addressed and i == len(resp),
            f"node={node_id} error={error_code}, consumed {i} of {len(resp)} bytes",
        )


def check_group_request_shapes(broker, apis):
    """ListGroups v4, DescribeGroups v5 and OffsetFetch v8 are each hand-encoded and none of
    them was covered here before.

    The assertion is that the reply parses to exactly its own length. A version gate written at
    the wrong number does not raise: it leaves the reader a field ahead or behind, which reads
    as plausible values and a buffer that ends in the wrong place."""
    if apis.get(16, (0, 0))[1] >= 4:
        resp = broker.send(16, 4, b"\x01" + b"\x00")   # empty states filter, tags
        i = skip_tags(resp, 4) + 4 + 2                  # header tags, throttle, error_code
        count, i = uvarint(resp, i)
        for _ in range(max(0, count - 1)):
            _, i = compact_string(resp, i)              # group_id
            _, i = compact_string(resp, i)              # protocol_type
            _, i = compact_string(resp, i)              # group_state, v4 only
            i = skip_tags(resp, i)
        i = skip_tags(resp, i)
        check("ListGroups v4 carries a group state per group", i == len(resp),
              f"consumed {i} of {len(resp)} bytes")

    if apis.get(15, (0, 0))[1] >= 5:
        body = b"\x02" + write_compact_string("tp-probe-group") + b"\x00" + b"\x00"
        resp = broker.send(15, 5, body)
        i = skip_tags(resp, 4) + 4
        count, i = uvarint(resp, i)
        for _ in range(max(0, count - 1)):
            i += 2                                      # error_code
            for _ in range(4):                          # group_id, state, protocol_type, protocol
                _, i = compact_string(resp, i)
            members, i = uvarint(resp, i)
            for _ in range(max(0, members - 1)):
                for _ in range(4):                      # member_id, instance_id, client_id, host
                    _, i = compact_string(resp, i)
                for _ in range(2):                      # metadata, assignment
                    size, i = uvarint(resp, i)
                    i += max(0, size - 1)
                i = skip_tags(resp, i)
            i += 4                                      # authorized_operations
            i = skip_tags(resp, i)
        i = skip_tags(resp, i)
        check("DescribeGroups v5 carries an instance id and authorized operations",
              i == len(resp), f"consumed {i} of {len(resp)} bytes")

    if apis.get(9, (0, 0))[1] >= 8:
        body = (b"\x02" + write_compact_string("tp-probe-group") + b"\x00" + b"\x00"
                + b"\x00" + b"\x00")
        resp = broker.send(9, 8, body)
        i = skip_tags(resp, 4) + 4
        groups, i = uvarint(resp, i)
        for _ in range(max(0, groups - 1)):
            _, i = compact_string(resp, i)              # group_id
            topics, i = uvarint(resp, i)
            for _ in range(max(0, topics - 1)):
                _, i = compact_string(resp, i)
                parts, i = uvarint(resp, i)
                for _ in range(max(0, parts - 1)):
                    i += 4 + 8 + 4                      # index, offset, leader_epoch
                    _, i = compact_string(resp, i)      # metadata
                    i += 2                              # error_code
                    i = skip_tags(resp, i)
                i = skip_tags(resp, i)
            i += 2                                      # group-level error_code
            i = skip_tags(resp, i)
        i = skip_tags(resp, i)
        check("OffsetFetch v8 groups its topics under a group and ends with a group error",
              i == len(resp), f"consumed {i} of {len(resp)} bytes")


def check_list_offsets_is_per_partition(broker, apis, topic):
    """ListOffsets answers per partition, which is why the driver splits one request per leader.

    The check is both that the encoding stays in step and that a partition's error arrives
    INSIDE a successful response. A broker that is not the leader of a partition reports it
    here, not as a request-level failure, and reading it as one is issue #2993."""
    if apis.get(2, (0, 0))[1] < 7:
        return
    body = struct.pack(">i", -1) + struct.pack(">b", 1)
    body += b"\x02" + write_compact_string(topic) + b"\x02"
    body += struct.pack(">i", 0) + struct.pack(">i", -1) + struct.pack(">q", -1) + b"\x00"
    body += b"\x00" + b"\x00"
    resp = broker.send(2, 7, body)
    i = skip_tags(resp, 4) + 4
    topics, i = uvarint(resp, i)
    saw_partition = False
    for _ in range(max(0, topics - 1)):
        _, i = compact_string(resp, i)
        parts, i = uvarint(resp, i)
        for _ in range(max(0, parts - 1)):
            i += 4 + 2 + 8 + 8 + 4   # index, error_code, timestamp, offset, leader_epoch
            i = skip_tags(resp, i)
            saw_partition = True
        i = skip_tags(resp, i)
    i = skip_tags(resp, i)
    check("ListOffsets v7 answers with an error code per partition",
          saw_partition and i == len(resp), f"consumed {i} of {len(resp)} bytes")


def check_delete_topics_shape(broker, apis):
    """DeleteTopics v5 still names topics; v6 switched to a 16-byte topic UUID, which is a
    different request rather than a bigger one. v5 also added a broker-supplied message the
    reader has to consume even though the app does not show it."""
    if apis.get(20, (0, 0))[1] < 5:
        return
    body = b"\x02" + write_compact_string("tp-probe-no-such-topic-9e3f")
    body += struct.pack(">i", 5000) + b"\x00"
    resp = broker.send(20, 5, body)
    i = skip_tags(resp, 4) + 4
    count, i = uvarint(resp, i)
    codes = []
    for _ in range(max(0, count - 1)):
        _, i = compact_string(resp, i)                  # name, nullable from v6 on
        codes.append(struct.unpack(">h", resp[i:i + 2])[0])
        i += 2
        _, i = compact_string(resp, i)                  # error_message
        i = skip_tags(resp, i)
    i = skip_tags(resp, i)
    check("DeleteTopics v5 names the topic and carries an error message",
          codes == [3] and i == len(resp),
          f"codes={codes}, consumed {i} of {len(resp)} bytes; 3 is UNKNOWN_TOPIC_OR_PARTITION")


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
        check_find_coordinator_field_order(broker, apis, brokers)
        check_group_request_shapes(broker, apis)
        check_list_offsets_is_per_partition(broker, apis, "tp-probe-crc")
        check_delete_topics_shape(broker, apis)
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
