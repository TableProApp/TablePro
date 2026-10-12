//
//  RemoteSQLiteAgentSource.swift
//  TablePro
//

import Foundation

/// The Python program TablePro runs on the SSH server to open a SQLite database with the server's
/// own `libsqlite3`, and the shell command that launches it.
///
/// The program is delivered inline over the SSH exec channel: base64 on the launcher's argument
/// list rather than a file written to the server, so nothing is installed and nothing is left
/// behind. It uses only the standard library, loads `libsqlite3` through `ctypes`, and speaks the
/// framed protocol in `SQLiteAgentProtocol`. It runs on the Python the server already carries;
/// measured across SQLite 3.26 to 3.54 and Python 3.6 to 3.14.
enum RemoteSQLiteAgentSource {
    /// The interpreters the launcher tries, in order. The bare names resolve through the login
    /// shell's `PATH`; the absolute paths cover RHEL/Rocky 8, whose only interpreter is
    /// `platform-python` under `/usr/libexec` with no `python3` on `PATH`.
    private static let interpreters = ["python3", "/usr/bin/python3", "/usr/libexec/platform-python"]

    /// The command handed to `libssh2_channel_process_startup("exec", …)`.
    ///
    /// The whole string is a fixed literal but for the base64 of the program, which is drawn from
    /// the base64 alphabet alone and is therefore safe as a bare shell word and inside single
    /// quotes under sh, bash, zsh, fish and csh (measured). The server never sees a byte of user
    /// data on this line: the database path and every value travel as framed protocol fields once
    /// the program is running, never as shell text.
    ///
    /// `-I` runs the interpreter isolated, so `PYTHON*` variables and the user site directory
    /// cannot redirect it. When no interpreter is found the launcher prints the agent's own notice
    /// on standard output, where it reaches the client as a launcher notice rather than being lost
    /// on standard error, and exits cleanly.
    static func launcherCommand() -> String {
        let encoded = Data(python.utf8).base64EncodedString()
        let loop = interpreters.map { interpreter -> String in
            let present = #"command -v "\#(interpreter)" >/dev/null 2>&1"#
            let run = #"exec "\#(interpreter)" -I -S -c "import base64,sys;exec(base64.b64decode(sys.argv[1]))" \#(encoded)"#
            return "if \(present); then \(run); fi"
        }
        .joined(separator: "; ")
        return "sh -c '" + loop + "; echo " + RemoteSQLiteWire.noPythonNotice + "; exit 0'"
    }

    static let python = #"""
import sys

if sys.version_info[0] < 3:
    sys.exit(2)

import ctypes
import ctypes.util
import os
import struct
import threading
import time

PROTOCOL_VERSION = 1

OP_HELLO = 0x01
OP_EXECUTE = 0x02
OP_CANCEL = 0x03
OP_HEARTBEAT = 0x04
OP_SET_BUSY = 0x05
OP_READY = 0x81
OP_FAILURE = 0x82
OP_HEADER = 0x83
OP_ROWS = 0x84
OP_DONE = 0x85
OP_ERROR = 0x86

FAIL_UNSUPPORTED_PROTOCOL = 1
FAIL_PYTHON_TOO_OLD = 2
FAIL_LIBRARY_UNAVAILABLE = 3
FAIL_OPEN_FAILED = 4
FAIL_CALLBACKS_UNAVAILABLE = 5
FAIL_MALFORMED = 6

SQLITE_OK = 0
SQLITE_DENY = 1
SQLITE_ROW = 100
SQLITE_DONE = 101
SQLITE_FUNCTION = 31
SQLITE_OPEN_READWRITE = 0x00000002
SQLITE_COL_NULL = 5
SQLITE_COL_BLOB = 4

DENIED_FUNCTIONS = (b"fts3_tokenizer", b"load_extension")
IDLE_DEADLINE_SECONDS = 60.0
BUSY_RETRY_MS = 10
ROW_BATCH = 500
BATCH_BYTES = 256 * 1024
MAX_FRAME = 64 * 1024 * 1024

stdout = sys.stdout.buffer
stdin = sys.stdin.buffer
write_lock = threading.Lock()
last_activity = [time.time()]
cancel_flag = [False]
busy_timeout_ms = [0]


def load_sqlite():
    names = ["libsqlite3.so.0", "libsqlite3.so", "libsqlite3.dylib"]
    found = ctypes.util.find_library("sqlite3")
    if found:
        names.append(found)
    for name in names:
        try:
            return ctypes.CDLL(name)
        except OSError:
            continue
    return None


def configure(lib):
    p = ctypes.c_void_p
    lib.sqlite3_libversion.restype = ctypes.c_char_p
    lib.sqlite3_open_v2.argtypes = [ctypes.c_char_p, ctypes.POINTER(p), ctypes.c_int, ctypes.c_char_p]
    lib.sqlite3_errmsg.argtypes = [p]
    lib.sqlite3_errmsg.restype = ctypes.c_char_p
    lib.sqlite3_extended_result_codes.argtypes = [p, ctypes.c_int]
    lib.sqlite3_set_authorizer.argtypes = [p, p, p]
    lib.sqlite3_busy_handler.argtypes = [p, p, p]
    lib.sqlite3_prepare_v2.argtypes = [p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(p), ctypes.POINTER(ctypes.c_char_p)]
    lib.sqlite3_column_count.argtypes = [p]
    lib.sqlite3_column_name.argtypes = [p, ctypes.c_int]
    lib.sqlite3_column_name.restype = ctypes.c_char_p
    lib.sqlite3_column_decltype.argtypes = [p, ctypes.c_int]
    lib.sqlite3_column_decltype.restype = ctypes.c_char_p
    lib.sqlite3_bind_null.argtypes = [p, ctypes.c_int]
    lib.sqlite3_bind_text.argtypes = [p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int, p]
    lib.sqlite3_bind_blob.argtypes = [p, ctypes.c_int, p, ctypes.c_int, p]
    lib.sqlite3_step.argtypes = [p]
    lib.sqlite3_column_type.argtypes = [p, ctypes.c_int]
    lib.sqlite3_column_bytes.argtypes = [p, ctypes.c_int]
    lib.sqlite3_column_blob.argtypes = [p, ctypes.c_int]
    lib.sqlite3_column_blob.restype = p
    lib.sqlite3_column_text.argtypes = [p, ctypes.c_int]
    lib.sqlite3_column_text.restype = p
    lib.sqlite3_changes.argtypes = [p]
    lib.sqlite3_finalize.argtypes = [p]
    lib.sqlite3_reset.argtypes = [p]
    lib.sqlite3_interrupt.argtypes = [p]
    lib.sqlite3_close_v2.argtypes = [p]


def frame(op, payload):
    return struct.pack(">I", len(payload) + 1) + bytes([op]) + payload


def send(op, payload):
    with write_lock:
        stdout.write(frame(op, payload))
        stdout.flush()


def send_failure(code, message):
    send(OP_FAILURE, struct.pack(">I", code) + encode_str(message))


def encode_bytes(data):
    return struct.pack(">I", len(data)) + data


def encode_str(text):
    return encode_bytes(text.encode("utf-8"))


def encode_value(kind, data):
    if kind == 0:
        return bytes([0])
    return bytes([kind]) + encode_bytes(data)


def read_exact(count):
    chunks = []
    remaining = count
    while remaining > 0:
        chunk = stdin.read(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame():
    header = read_exact(4)
    if header is None:
        return None
    length = struct.unpack(">I", header)[0]
    if length < 1 or length > MAX_FRAME:
        return None
    body = read_exact(length)
    if body is None:
        return None
    return body[0], body[1:]


class Cursor(object):
    def __init__(self, data):
        self.data = data
        self.offset = 0

    def u8(self):
        value = self.data[self.offset]
        self.offset += 1
        return value

    def u32(self):
        value = struct.unpack(">I", self.data[self.offset:self.offset + 4])[0]
        self.offset += 4
        return value

    def blob(self):
        length = self.u32()
        value = self.data[self.offset:self.offset + length]
        self.offset += length
        return value

    def text(self):
        return self.blob().decode("utf-8")

    def value(self):
        tag = self.u8()
        if tag == 0:
            return (0, None)
        return (tag, self.blob())


def make_authorizer():
    authz_type = ctypes.CFUNCTYPE(
        ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p
    )

    def authorizer(_ctx, action, arg1, arg2, _db, _trigger):
        if action == SQLITE_FUNCTION and arg2 is not None and arg2.lower() in DENIED_FUNCTIONS:
            return SQLITE_DENY
        return SQLITE_OK

    return authz_type(authorizer)


def make_busy_handler(lib, db):
    busy_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_int)

    def handler(_ctx, count):
        if cancel_flag[0]:
            return 0
        limit = busy_timeout_ms[0]
        if limit > 0 and count * BUSY_RETRY_MS >= limit:
            return 0
        time.sleep(BUSY_RETRY_MS / 1000.0)
        return 1

    return busy_type(handler)


def open_database(lib, path, busy_ms):
    db = ctypes.c_void_p()
    expanded = os.path.expanduser(path)
    rc = lib.sqlite3_open_v2(expanded.encode("utf-8"), ctypes.byref(db), SQLITE_OPEN_READWRITE, None)
    if rc != SQLITE_OK:
        message = "unable to open database"
        if db.value:
            message = lib.sqlite3_errmsg(db).decode("utf-8", "replace")
            lib.sqlite3_close_v2(db)
        return None, message
    lib.sqlite3_extended_result_codes(db, 1)
    busy_timeout_ms[0] = busy_ms
    return db, None


TRANSIENT = ctypes.cast(-1, ctypes.c_void_p)


def bind_parameters(lib, stmt, parameters):
    for index, item in enumerate(parameters):
        position = index + 1
        tag, data = item
        if tag == 0:
            lib.sqlite3_bind_null(stmt, position)
        elif tag == 1:
            lib.sqlite3_bind_text(stmt, position, data, len(data), TRANSIENT)
        else:
            buffer = ctypes.create_string_buffer(data, len(data)) if data else ctypes.create_string_buffer(0)
            lib.sqlite3_bind_blob(stmt, position, buffer, len(data), TRANSIENT)


def read_row(lib, stmt, column_count):
    row = []
    for index in range(column_count):
        column_type = lib.sqlite3_column_type(stmt, index)
        if column_type == SQLITE_COL_NULL:
            row.append((0, b""))
        elif column_type == SQLITE_COL_BLOB:
            length = lib.sqlite3_column_bytes(stmt, index)
            pointer = lib.sqlite3_column_blob(stmt, index)
            data = ctypes.string_at(pointer, length) if length and pointer else b""
            row.append((2, data))
        else:
            pointer = lib.sqlite3_column_text(stmt, index)
            length = lib.sqlite3_column_bytes(stmt, index)
            data = ctypes.string_at(pointer, length) if length and pointer else b""
            row.append((1, data))
    return row


def execute(lib, db, sql, parameters, row_cap):
    cancel_flag[0] = False
    stmt = ctypes.c_void_p()
    rc = lib.sqlite3_prepare_v2(db, sql.encode("utf-8"), -1, ctypes.byref(stmt), None)
    if rc != SQLITE_OK or not stmt.value:
        if stmt.value:
            lib.sqlite3_finalize(stmt)
        send(OP_ERROR, struct.pack(">I", rc & 0xFFFFFFFF) + encode_str(lib.sqlite3_errmsg(db).decode("utf-8", "replace")))
        return
    try:
        bind_parameters(lib, stmt, parameters)
        column_count = lib.sqlite3_column_count(stmt)
        header = struct.pack(">I", column_count)
        for index in range(column_count):
            name = lib.sqlite3_column_name(stmt, index)
            header += encode_str(name.decode("utf-8", "replace") if name else "column_" + str(index))
            decltype = lib.sqlite3_column_decltype(stmt, index)
            if decltype is not None:
                header += bytes([1]) + encode_str(decltype.decode("utf-8", "replace"))
            else:
                header += bytes([0])
        send(OP_HEADER, header)

        batch = []
        batch_bytes = 0
        row_count = 0
        truncated = False
        while True:
            step = lib.sqlite3_step(stmt)
            if step != SQLITE_ROW:
                break
            if row_cap > 0 and row_count >= row_cap:
                truncated = True
                break
            row = read_row(lib, stmt, column_count)
            batch.append(row)
            row_count += 1
            for _, data in row:
                batch_bytes += len(data)
            if len(batch) >= ROW_BATCH or batch_bytes >= BATCH_BYTES:
                send_rows(column_count, batch)
                batch = []
                batch_bytes = 0
        if batch:
            send_rows(column_count, batch)
        if step != SQLITE_ROW and step != SQLITE_DONE and not truncated:
            send(OP_ERROR, struct.pack(">I", step & 0xFFFFFFFF) + encode_str(lib.sqlite3_errmsg(db).decode("utf-8", "replace")))
            return
        changes = lib.sqlite3_changes(db) if column_count == 0 else 0
        send(OP_DONE, struct.pack(">q", changes) + bytes([1 if truncated else 0]))
    finally:
        lib.sqlite3_finalize(stmt)


def send_rows(column_count, batch):
    payload = struct.pack(">I", column_count) + struct.pack(">I", len(batch))
    parts = [payload]
    for row in batch:
        for kind, data in row:
            parts.append(encode_value(kind, data))
    send(OP_ROWS, b"".join(parts))


def reader_loop(lib, db, request_queue, condition):
    while True:
        message = read_frame()
        last_activity[0] = time.time()
        if message is None:
            with condition:
                request_queue.append(None)
                condition.notify()
            return
        op, payload = message
        if op == OP_CANCEL:
            cancel_flag[0] = True
            lib.sqlite3_interrupt(db)
        elif op == OP_HEARTBEAT:
            continue
        elif op == OP_SET_BUSY:
            busy_timeout_ms[0] = Cursor(payload).u32()
        else:
            with condition:
                request_queue.append((op, payload))
                condition.notify()


def watchdog(lib, db):
    while True:
        time.sleep(5.0)
        if time.time() - last_activity[0] > IDLE_DEADLINE_SECONDS:
            lib.sqlite3_interrupt(db)
            os._exit(0)


def main():
    if sys.version_info < (3, 6):
        send_failure(FAIL_PYTHON_TOO_OLD, "python 3.6 or newer is required")
        return

    lib = load_sqlite()
    if lib is None:
        send_failure(FAIL_LIBRARY_UNAVAILABLE, "libsqlite3 could not be loaded on the server")
        return
    configure(lib)

    hello = read_frame()
    last_activity[0] = time.time()
    if hello is None or hello[0] != OP_HELLO:
        send_failure(FAIL_MALFORMED, "expected HELLO")
        return
    cursor = Cursor(hello[1])
    client_version = cursor.u32()
    path = cursor.text()
    busy_ms = cursor.u32()
    if client_version != PROTOCOL_VERSION:
        send_failure(FAIL_UNSUPPORTED_PROTOCOL, "protocol version mismatch")
        return

    db, error = open_database(lib, path, busy_ms)
    if db is None:
        send_failure(FAIL_OPEN_FAILED, error)
        return

    authorizer = make_authorizer()
    busy_handler = make_busy_handler(lib, db)
    keep_alive = (authorizer, busy_handler)
    try:
        lib.sqlite3_set_authorizer(db, ctypes.cast(authorizer, ctypes.c_void_p), None)
        lib.sqlite3_busy_handler(db, ctypes.cast(busy_handler, ctypes.c_void_p), None)
        probe = ctypes.c_void_p()
        rc = lib.sqlite3_prepare_v2(db, b"SELECT 1", -1, ctypes.byref(probe), None)
        if rc != SQLITE_OK:
            raise RuntimeError("callback self-test failed")
        lib.sqlite3_finalize(probe)
    except Exception:
        send_failure(FAIL_CALLBACKS_UNAVAILABLE, "the server rejected the required callbacks")
        return

    send(OP_READY, struct.pack(">I", PROTOCOL_VERSION)
         + encode_str(lib.sqlite3_libversion().decode("utf-8", "replace"))
         + encode_str("%d.%d.%d" % sys.version_info[:3]))

    request_queue = []
    condition = threading.Condition()
    threading.Thread(target=reader_loop, args=(lib, db, request_queue, condition), daemon=True).start()
    threading.Thread(target=watchdog, args=(lib, db), daemon=True).start()

    _ = keep_alive
    while True:
        with condition:
            while not request_queue:
                condition.wait()
            item = request_queue.pop(0)
        if item is None:
            break
        op, payload = item
        if op != OP_EXECUTE:
            continue
        request = Cursor(payload)
        sql = request.text()
        count = request.u32()
        parameters = [request.value() for _ in range(count)]
        row_cap = request.u32()
        execute(lib, db, sql, parameters, row_cap)

    lib.sqlite3_close_v2(db)


main()
"""#
}
