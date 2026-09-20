#!/usr/bin/env bash
#
# Check that OracleCoreConnection commits the way TablePro presents every engine, against a real Oracle server.
#
# Oracle never commits on its own and oracle-nio sends no commit unless a statement asks for one, so a write the
# driver runs without the commit flag stays invisible to every other session, and keeps its row locks, until something
# commits it. OracleSessionTransaction decides per statement whether the flag is sent. This runs each rule through the
# same OracleCoreConnection the plugin and the iOS driver use, and reads the result from a second session.
#
# Usage:
#   scripts/check-oracle-autocommit.sh [host] [port] [service] [user] [password]
#
# Defaults suit a throwaway Oracle Free container:
#   docker run -d --name oracle-probe -p 1521:1521 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# The user needs CREATE TABLE. It opens two sessions, creates tables prefixed TP_AC_ and drops them again. Exits
# non-zero on a disagreement, 3 when a prerequisite is missing.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1521}"
SERVICE="${3:-FREEPDB1}"
USER_NAME="${4:-probe}"
PASSWORD="${5:-probe_pw}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
command -v swift > /dev/null || {
    echo "swift not found" >&2
    exit 3
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/Probe"

cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProOracle")],
    targets: [
        .executableTarget(
            name: "Probe",
            dependencies: [.product(name: "TableProOracleCore", package: "TableProOracle")]
        )
    ]
)
EOF

cat > "$WORK/Sources/Probe/main.swift" <<'EOF'
import Foundation
import TableProOracleCore

let arguments = CommandLine.arguments

func session() -> OracleCoreConnection {
    OracleCoreConnection(options: OracleConnectionOptions(
        host: arguments[1], port: Int(arguments[2]) ?? 1_521, user: arguments[4], password: arguments[5],
        identifierMode: .service, serviceName: arguments[3]
    ))
}

let writer = session()
let reader = session()
do {
    try await writer.connect()
    try await reader.connect()
} catch {
    print("cannot connect: \(error)")
    exit(3)
}

@discardableResult
func run(_ sql: String, on connection: OracleCoreConnection = writer) async -> Error? {
    do {
        _ = try await connection.executeQuery(sql)
        return nil
    } catch {
        return error
    }
}

func stream(_ sql: String) async -> Error? {
    let rows = AsyncThrowingStream<OracleStreamElement, Error> { continuation in
        Task {
            do {
                try await writer.streamQuery(sql, continuation: continuation)
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
    do {
        for try await _ in rows {}
        return nil
    } catch {
        return error
    }
}

func rows(_ sql: String, on connection: OracleCoreConnection) async -> [String] {
    let result = try? await connection.executeQuery(sql)
    return result?.rows.compactMap { $0.first?.stringValue } ?? []
}

func readerSees(_ value: Int) async -> Bool {
    await rows("SELECT TO_CHAR(COUNT(*)) FROM TP_AC_T WHERE X = \(value)", on: reader) == ["1"]
}

var disagreements = 0
@MainActor func check(_ holds: Bool, _ rule: String) {
    print("\(holds ? "ok  " : "FAIL") \(rule)")
    if !holds { disagreements += 1 }
}

await run("BEGIN EXECUTE IMMEDIATE 'DROP TABLE TP_AC_T PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;")
await run("BEGIN EXECUTE IMMEDIATE 'DROP TABLE TP_AC_D PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;")
if let failure = await run("CREATE TABLE TP_AC_T (X NUMBER PRIMARY KEY)") {
    print("cannot create TP_AC_T: \(failure)")
    exit(3)
}
await run("""
    CREATE TABLE TP_AC_D (X NUMBER CONSTRAINT TP_AC_D_POSITIVE CHECK (X > 0) DEFERRABLE INITIALLY DEFERRED)
    """)

await run("INSERT INTO TP_AC_T VALUES (1)")
check(await readerSees(1), "a write run on its own is visible to another session at once")

_ = await stream("INSERT INTO TP_AC_T VALUES (2)")
check(await readerSees(2), "a streamed write run on its own is visible to another session at once")

await run("UPDATE TP_AC_T SET X = X WHERE X = 1")
let rowFree = await rows("SELECT TO_CHAR(X) FROM TP_AC_T WHERE X = 1 FOR UPDATE NOWAIT", on: reader) == ["1"]
await run("ROLLBACK", on: reader)
check(rowFree, "a write run on its own holds no row lock afterwards")

await run("INSERT INTO TP_AC_T SELECT LEVEL + 100 FROM DUAL CONNECT BY LEVEL <= 50")
let locked = (try? await writer.executeQuery("SELECT X FROM TP_AC_T WHERE X > 100 FOR UPDATE").rows.count) ?? -1
check(locked == 50, "SELECT ... FOR UPDATE reads every row, not only the first fetch (read \(locked))")
let rowsHeld = await run("SELECT X FROM TP_AC_T WHERE X = 101 FOR UPDATE NOWAIT", on: reader) != nil
await run("INSERT INTO TP_AC_T VALUES (3)")
let rowsReleased = await run("SELECT X FROM TP_AC_T WHERE X = 101 FOR UPDATE NOWAIT", on: reader) == nil
await run("ROLLBACK", on: reader)
check(rowsHeld && rowsReleased, "SELECT ... FOR UPDATE holds its locks until the next statement that is not a query")

writer.beginTransaction()
await run("INSERT INTO TP_AC_T VALUES (10)")
await run("INSERT INTO TP_AC_T VALUES (11)")
let pendingBeforeCommit = !(await readerSees(10))
await run("COMMIT")
let committed10 = await readerSees(10)
let committed11 = await readerSees(11)
check(pendingBeforeCommit && committed10 && committed11 && !writer.holdsTransaction,
      "writes inside an opened transaction stay pending until COMMIT, which ends it")
await run("INSERT INTO TP_AC_T VALUES (12)")
check(await readerSees(12), "a write after COMMIT commits as it runs again")

writer.beginTransaction()
await run("INSERT INTO TP_AC_T VALUES (20)")
let duplicate = await run("INSERT INTO TP_AC_T VALUES (20)")
await run("ROLLBACK")
let writerKept20 = await rows("SELECT TO_CHAR(COUNT(*)) FROM TP_AC_T WHERE X = 20", on: writer) != ["0"]
let readerSees20 = await readerSees(20)
check(duplicate != nil && !writerKept20 && !readerSees20 && !writer.holdsTransaction,
      "a failed statement inside an opened transaction rolls back with the rest of it")

await run("SAVEPOINT TP_AC_S")
let savepointOpened = writer.holdsTransaction
await run("INSERT INTO TP_AC_T VALUES (30)")
await run("ROLLBACK TO TP_AC_S")
await run("INSERT INTO TP_AC_T VALUES (31)")
let pendingAfterSavepoint = !(await readerSees(31))
let openAfterRollbackTo = writer.holdsTransaction
await run("COMMIT")
let keptBeforeSavepoint = await readerSees(30)
let keptAfterSavepoint = await readerSees(31)
check(savepointOpened && pendingAfterSavepoint && openAfterRollbackTo && !keptBeforeSavepoint && keptAfterSavepoint,
      "SAVEPOINT opens a transaction that ROLLBACK TO keeps open")

await run("SET TRANSACTION NAME 'tp_ac'")
await run("INSERT INTO TP_AC_T VALUES (40)")
let pendingAfterSetTransaction = !(await readerSees(40))
await run("ROLLBACK")
let discarded = !(await readerSees(40))
check(pendingAfterSetTransaction && discarded && !writer.holdsTransaction,
      "SET TRANSACTION opens a transaction and ROLLBACK discards it")

await run("LOCK TABLE TP_AC_T IN EXCLUSIVE MODE")
let lockHeld = await run("LOCK TABLE TP_AC_T IN EXCLUSIVE MODE NOWAIT", on: reader) != nil
await run("COMMIT")
let lockReleased = await run("LOCK TABLE TP_AC_T IN EXCLUSIVE MODE NOWAIT", on: reader) == nil
await run("ROLLBACK", on: reader)
check(lockHeld && lockReleased, "LOCK TABLE holds its lock until COMMIT")

await run("BEGIN INSERT INTO TP_AC_T VALUES (50); END;")
check(await readerSees(50), "a PL/SQL block that writes commits as it runs")

writer.beginTransaction()
await run("INSERT INTO TP_AC_T VALUES (55)")
let malformed = await run("COMMIT BOGUS")
let heldAfterMalformed = writer.holdsTransaction
let pendingAfterMalformed = !(await readerSees(55))
await run("ROLLBACK")
let rolledBackAfterMalformed = !(await readerSees(55))
check(malformed != nil && heldAfterMalformed && pendingAfterMalformed && rolledBackAfterMalformed,
      "a COMMIT the server cannot parse leaves the transaction open for the ROLLBACK after it")

writer.beginTransaction()
await run("INSERT INTO TP_AC_D VALUES (-1)")
let refused = await run("COMMIT")
let deferredGone = await rows("SELECT TO_CHAR(COUNT(*)) FROM TP_AC_D", on: writer) == ["0"]
check(refused != nil && deferredGone && !writer.holdsTransaction, "a COMMIT the server refuses ends the transaction")

writer.beginTransaction()
await run("INSERT INTO TP_AC_T VALUES (60)")
writer.disconnect()
let lost = await run("INSERT INTO TP_AC_T VALUES (61)")
let ranAfterLoss = await readerSees(61)
check((lost as? OracleCoreError) == .transactionLost && !writer.holdsTransaction && !ranAfterLoss,
      "a write after the transaction's connection closed reports the transaction lost and runs nothing")
await run("INSERT INTO TP_AC_T VALUES (62)")
check(await readerSees(62), "the next write commits as it runs on the new connection")
let closeCommitted = await readerSees(60)
print("info a graceful close with a write pending \(closeCommitted ? "committed" : "rolled back") it")

await run("DROP TABLE TP_AC_T PURGE")
await run("DROP TABLE TP_AC_D PURGE")
writer.disconnect()
reader.disconnect()
try? await Task.sleep(nanoseconds: 500_000_000)

print(disagreements == 0 ? "Oracle commits as TablePro presents it on this server." : "\(disagreements) disagreement(s).")
exit(disagreements == 0 ? 0 : 1)
EOF

echo "Building the probe against Packages/TableProOracle (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
"$WORK/.build/debug/Probe" "$HOST" "$PORT" "$SERVICE" "$USER_NAME" "$PASSWORD" 2> /dev/null
