#!/usr/bin/env python3
"""Fake TDS 7.4 endpoint that asserts the FEDAUTH bytes a client emits.

Speaks just enough of MS-TDS to get a client from PRELOGIN to LOGIN7:
answers PRELOGIN with ENCRYPTION=NOT_SUP so LOGIN7 arrives in the clear,
and with FEDAUTHREQUIRED=1 so the client has to echo it back.
"""

import json
import socket
import struct
import sys

PRELOGIN = 0x12
LOGIN7 = 0x10
REPLY = 0x04

OPT_VERSION = 0x00
OPT_ENCRYPTION = 0x01
OPT_FEDAUTHREQUIRED = 0x06
OPT_TERMINATOR = 0xFF

ENCRYPT_NOT_SUP = 0x02

FEATURE_UTF8 = 0x0A
FEATURE_FEDAUTH = 0x02
FEATURE_TERMINATOR = 0xFF

FEDAUTH_SECURITYTOKEN = 0x01

OPTFLAGS2_INTEGRATED_SECURITY = 0x80
OPTFLAGS3_EXTENSION = 0x10


class Failure(Exception):
    pass


class Done(Exception):
    pass


def read_packet(conn):
    header = b""
    while len(header) < 8:
        chunk = conn.recv(8 - len(header))
        if not chunk:
            raise Failure("connection closed while reading the packet header")
        header += chunk
    ptype, _status, length = struct.unpack(">BBH", header[:4])
    body = b""
    while len(body) < length - 8:
        chunk = conn.recv(length - 8 - len(body))
        if not chunk:
            raise Failure("connection closed while reading the packet body")
        body += chunk
    return ptype, body


def parse_prelogin(body):
    options = {}
    i = 0
    while True:
        if i >= len(body):
            raise Failure("PRELOGIN option table ran off the end with no terminator")
        token = body[i]
        if token == OPT_TERMINATOR:
            break
        if i + 5 > len(body):
            raise Failure("truncated PRELOGIN option entry")
        offset, length = struct.unpack(">HH", body[i + 1:i + 5])
        if offset + length > len(body):
            raise Failure(
                "PRELOGIN option 0x%02x points outside the packet (off=%d len=%d size=%d)"
                % (token, offset, length, len(body))
            )
        options[token] = body[offset:offset + length]
        i += 5
    return options


def build_prelogin_response():
    entries = [
        (OPT_VERSION, bytes([0x0C, 0x00, 0x07, 0xD0, 0x00, 0x00])),
        (OPT_ENCRYPTION, bytes([ENCRYPT_NOT_SUP])),
        (OPT_FEDAUTHREQUIRED, bytes([0x01])),
    ]
    table = b""
    data = b""
    data_start = len(entries) * 5 + 1
    for token, payload in entries:
        table += struct.pack(">BHH", token, data_start + len(data), len(payload))
        data += payload
    table += bytes([OPT_TERMINATOR])
    body = table + data
    return struct.pack(">BBHHBB", REPLY, 0x01, 8 + len(body), 0, 1, 0) + body


def parse_login7(body):
    if len(body) < 94:
        raise Failure("LOGIN7 shorter than the fixed TDS 7.2+ header (%d bytes)" % len(body))
    declared = struct.unpack("<I", body[0:4])[0]
    if declared != len(body):
        raise Failure("LOGIN7 Length field %d does not match the %d bytes received" % (declared, len(body)))

    login = {
        "tds_version": "0x%08x" % struct.unpack("<I", body[4:8])[0],
        "option_flags2": body[25],
        "option_flags3": body[27],
    }

    def offset_pair(at):
        return struct.unpack("<HH", body[at:at + 4])

    _, login["cch_user_name"] = offset_pair(40)
    _, login["cch_password"] = offset_pair(44)
    ib_extension, cb_extension = offset_pair(56)
    login["cb_extension"] = cb_extension

    if not login["option_flags3"] & OPTFLAGS3_EXTENSION:
        raise Failure("OptionFlags3 fExtension is not set, so no FeatureExt is present")
    if cb_extension != 4:
        raise Failure("cbExtension is %d, MS-TDS requires 4" % cb_extension)
    if ib_extension + 4 > len(body):
        raise Failure("ibExtension points outside the packet")

    feature_offset = struct.unpack("<I", body[ib_extension:ib_extension + 4])[0]
    if feature_offset >= len(body):
        raise Failure("FeatureExt offset %d points outside the packet" % feature_offset)

    features = {}
    order = []
    i = feature_offset
    while True:
        if i >= len(body):
            raise Failure("FeatureExt ran off the end with no terminator")
        feature_id = body[i]
        if feature_id == FEATURE_TERMINATOR:
            break
        if i + 5 > len(body):
            raise Failure("truncated FeatureExt entry")
        data_len = struct.unpack("<I", body[i + 1:i + 5])[0]
        if i + 5 + data_len > len(body):
            raise Failure(
                "FeatureExt 0x%02x claims %d bytes but only %d remain"
                % (feature_id, data_len, len(body) - i - 5)
            )
        features[feature_id] = body[i + 5:i + 5 + data_len]
        order.append(feature_id)
        i += 5 + data_len
    login["feature_order"] = order
    login["features"] = features
    return login


def check(results, name, condition, detail):
    results.append({"name": name, "ok": bool(condition), "detail": detail})


def main():
    mode = sys.argv[1]
    expected_token = sys.argv[2]
    out_path = sys.argv[3]

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    print(port, flush=True)

    server.settimeout(30)
    results = []
    try:
        conn, _ = server.accept()
        conn.settimeout(30)

        ptype, body = read_packet(conn)
        check(results, "prelogin.packet_type", ptype == PRELOGIN,
              "expected 0x12, got 0x%02x" % ptype)
        options = parse_prelogin(body)
        fedauth_required = options.get(OPT_FEDAUTHREQUIRED)
        if mode == "fedauth":
            check(results, "prelogin.fedauthrequired_present", fedauth_required is not None,
                  "PRELOGIN option 0x06 present: %s" % (fedauth_required is not None))
            check(results, "prelogin.fedauthrequired_value", fedauth_required == b"\x01",
                  "MS-TDS requires the client to send 0x01, got %r" % (fedauth_required,))
        else:
            check(results, "prelogin.fedauthrequired_absent", fedauth_required is None,
                  "a password login must not advertise FEDAUTHREQUIRED, got %r" % (fedauth_required,))
        check(results, "prelogin.other_options_intact",
              OPT_VERSION in options and OPT_ENCRYPTION in options,
              "VERSION and ENCRYPTION still parse: %r" % (sorted(options),))

        conn.sendall(build_prelogin_response())

        ptype, body = read_packet(conn)
        check(results, "login7.packet_type", ptype == LOGIN7,
              "expected 0x10, got 0x%02x" % ptype)
        login = parse_login7(body)

        check(results, "login7.utf8_feature_preserved",
              FEATURE_UTF8 in login["features"],
              "existing UTF-8 feature still emitted: %s" % (FEATURE_UTF8 in login["features"]))

        if mode != "fedauth":
            check(results, "login7.fedauth_feature_absent",
                  FEATURE_FEDAUTH not in login["features"],
                  "a password login must carry no FEDAUTH feature, ids seen: %s"
                  % ["0x%02x" % f for f in login["feature_order"]])
            check(results, "login7.username_sent",
                  login["cch_user_name"] == len(expected_token),
                  "cchUserName=%d, expected %d" % (login["cch_user_name"], len(expected_token)))
            check(results, "login7.password_sent", login["cch_password"] > 0,
                  "cchPassword=%d" % login["cch_password"])
            conn.close()
            raise Done()

        check(results, "login7.fint_security_off",
              not login["option_flags2"] & OPTFLAGS2_INTEGRATED_SECURITY,
              "MS-TDS: fIntSecurity MUST be 0 when FEDAUTH is present "
              "(OptionFlags2=0x%02x)" % login["option_flags2"])
        check(results, "login7.username_empty", login["cch_user_name"] == 0,
              "cchUserName=%d" % login["cch_user_name"])
        check(results, "login7.password_empty", login["cch_password"] == 0,
              "cchPassword=%d" % login["cch_password"])

        check(results, "login7.fedauth_feature_present",
              FEATURE_FEDAUTH in login["features"],
              "FeatureExt ids seen: %s" % ["0x%02x" % f for f in login["feature_order"]])

        fedauth = login["features"].get(FEATURE_FEDAUTH, b"")
        expected_wide = expected_token.encode("utf-16-le")
        check(results, "login7.fedauth_datalen",
              len(fedauth) == 1 + 4 + len(expected_wide),
              "FeatureDataLen=%d, expected %d (1 options + 4 length + %d token)"
              % (len(fedauth), 1 + 4 + len(expected_wide), len(expected_wide)))

        if len(fedauth) >= 5:
            options_byte = fedauth[0]
            library = options_byte >> 1
            echo = options_byte & 0x01
            token_len = struct.unpack("<I", fedauth[1:5])[0]
            token = fedauth[5:5 + token_len]
            check(results, "login7.fedauth_library",
                  library == FEDAUTH_SECURITYTOKEN,
                  "bFedAuthLibrary=%d in bits 1-7, expected SECURITYTOKEN=1 "
                  "(Options byte 0x%02x)" % (library, options_byte))
            check(results, "login7.fedauth_echo", echo == 1,
                  "fFedAuthEcho=%d in bit 0, server sent FEDAUTHREQUIRED=1 so it must echo 1"
                  % echo)
            check(results, "login7.fedauth_token_len",
                  token_len == len(expected_wide),
                  "TokenLength=%d, expected %d" % (token_len, len(expected_wide)))
            check(results, "login7.fedauth_token_utf16le",
                  token == expected_wide,
                  "token round-trips as UTF-16LE: %s"
                  % (token.decode("utf-16-le", "replace") == expected_token))
        conn.close()
    except Done:
        pass
    except Failure as exc:
        check(results, "harness", False, str(exc))
    except socket.timeout:
        check(results, "harness", False, "timed out waiting for the client")
    finally:
        server.close()

    with open(out_path, "w") as handle:
        json.dump(results, handle, indent=2)

    failed = [r for r in results if not r["ok"]]
    for r in results:
        print("%s %s -- %s" % ("PASS" if r["ok"] else "FAIL", r["name"], r["detail"]))
    print("\n%d checks, %d failed" % (len(results), len(failed)))
    return 1 if failed or not results else 0


if __name__ == "__main__":
    sys.exit(main())
