#!/usr/bin/env bash
#
# Check how the SQL Server driver reads a batch, against a real server, through the driver's own sources.
#
# T-SQL scopes a DECLAREd variable, a table variable and a TRY...CATCH to one batch, so the editor sends a script
# whole and the driver has to hand back everything the batch answered (#3078). db-lib makes that easy to get wrong in
# ways no unit test can see, because each one depends on what the server sends and in what order:
#
#   - dbresults answers FAIL for a failed statement and then carries on to the next one. Stopping there left the
#     connection answering every later request with db-lib 20019 until it reconnected.
#   - An error inside a SELECT (1/0, a conversion that fails part way through a scan) arrives only through the message
#     handler, while dbresults and dbnextrow report success. It read as an empty or short result.
#   - A later result set can be wider than the first. The stream path indexed the first one's columns with the later
#     one's count and trapped.
#   - A capped read that cancelled the rest of its request sent the server an attention, which under
#     SET XACT_ABORT ON rolled back the session's open transaction without a word. One that left the rest unread
#     instead kept its SELECT suspended on the server holding its locks, so another session's ALTER TABLE failed with
#     Msg 1222, and the connection's next call had to read every remaining row before the server answered it.
#   - sp_executesql runs its text one scope down, so a parameterized batch wrapped in it failed a BEGIN TRAN with
#     Msg 266 and lost its #temp tables, and its generated names collided with the script's own variables (Msg 134).
#     The declaration that binds values in the batch instead reports a row count of its own, and a procedure called
#     without EXEC fails behind it.
#   - A Stop pressed while a statement waited behind another call was forgotten, and the statement was sent and
#     committed anyway.
#   - A Stop called dbcancel from its own thread, and dbcancel reads the server's answer on the thread that calls it.
#     The thread reading the connection then waited forever for packets the Stop had already read: during a large
#     result, and during a read blocked on another session's lock.
#   - Past the errors a read keeps, a failing statement looked like db-lib failing the whole request.
#   - A disconnect left the statement running on the server and committing, where a client that closes its socket
#     ends it. db-lib closes the handle only once the read in progress returns, and the disconnect took away the gate
#     the interrupt is found through, so a Stop pressed just before it was lost. Closing a window stops and then
#     disconnects; Disconnect disconnects and then stops.
#
# So this builds a harness from the real Plugins/MSSQLDriverPlugin sources, the TableProCore package and the shipped
# Libs/libsybdb.a, runs each case through MSSQLPluginDriver, and fails when any answer differs. A FreeTDS bump or a
# change to the reader re-checks it.
#
# Usage:
#   scripts/check-mssql-batch-results.sh [host] [port] [user] [database]
#
# The database defaults to tablepro_batch_check and is created when missing, so runs that share a server can each
# name their own.
#
# The password comes from MSSQL_SA_PASSWORD. With no server listening on host:port, the script starts
# mcr.microsoft.com/azure-sql-edge in Docker as tablepro-mssql-check (or TP_MSSQL_CONTAINER), generating a password
# when none is set, and leaves it running for the next run. Exits 1 when a check fails, 3 when it cannot run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-14339}"
USER_NAME="${3:-sa}"
DATABASE="${4:-tablepro_batch_check}"
PASSWORD="${MSSQL_SA_PASSWORD:-}"
CONTAINER="${TP_MSSQL_CONTAINER:-tablepro-mssql-check}"
IMAGE="mcr.microsoft.com/azure-sql-edge:latest"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$ROOT/Libs/libsybdb.a" ] || {
    echo "not found: Libs/libsybdb.a (run scripts/download-libs.sh)" >&2
    exit 3
}

listening() {
    nc -z "$HOST" "$PORT" > /dev/null 2>&1
}

if ! listening; then
    command -v docker > /dev/null 2>&1 || {
        echo "no SQL Server at $HOST:$PORT and no docker to start one" >&2
        exit 3
    }
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        echo "starting container $CONTAINER"
        docker start "$CONTAINER" > /dev/null || exit 3
    else
        if [ -z "$PASSWORD" ]; then
            PASSWORD="TpCheck#$(openssl rand -hex 8)"
            echo "generated a password for $CONTAINER; export MSSQL_SA_PASSWORD='$PASSWORD' to reuse it"
        fi
        echo "starting $IMAGE as $CONTAINER on $HOST:$PORT"
        docker run -d --name "$CONTAINER" -e ACCEPT_EULA=1 -e "MSSQL_SA_PASSWORD=$PASSWORD" \
            -p "$HOST:$PORT:1433" "$IMAGE" > /dev/null || exit 3
    fi
    for _ in $(seq 1 60); do
        listening && break
        sleep 2
    done
fi

[ -n "$PASSWORD" ] || {
    echo "no password: set MSSQL_SA_PASSWORD for the server at $HOST:$PORT" >&2
    exit 3
}

mkdir -p "$WORK/Sources/Check"
ln -s "$ROOT/Plugins/MSSQLDriverPlugin/CFreeTDS" "$WORK/CFreeTDS"
for source in "$ROOT"/Plugins/MSSQLDriverPlugin/*.swift; do
    ln -s "$source" "$WORK/Sources/Check/$(basename "$source")"
done

cat > "$WORK/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSSQLBatchCheck",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .systemLibrary(name: "CFreeTDS", path: "CFreeTDS"),
        .executableTarget(
            name: "Check",
            dependencies: [
                "CFreeTDS",
                .product(name: "TableProPluginKit", package: "TableProCore"),
                .product(name: "TableProCoreTypes", package: "TableProCore"),
                .product(name: "TableProMSSQLCore", package: "TableProCore"),
                .product(name: "TableProLogRedaction", package: "TableProCore"),
            ],
            path: "Sources/Check",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags([
                "-L$ROOT/Libs", "-L$ROOT/Libs/dylibs", "-lsybdb", "-lssl.3", "-lcrypto.3", "-liconv",
                "-framework", "GSS", "-lcom_err", "-Xlinker", "-rpath", "-Xlinker", "$ROOT/Libs/dylibs",
            ])]
        ),
    ]
)
MANIFEST

cat > "$WORK/Sources/Check/Check.swift" << 'SWIFT'
import Foundation
import TableProPluginKit

@main
enum Check {
    nonisolated(unsafe) static var failures = 0

    static let database = ProcessInfo.processInfo.environment["TP_CHECK_DATABASE"] ?? "tablepro_batch_check"

    static func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS: \(label)")
        } else {
            failures += 1
            print("FAIL: \(label) \(detail())")
        }
    }

    static func columns(_ result: PluginQueryResult) -> [String] { result.columns }

    static func crossJoin(rows: Int) -> String {
        "SELECT TOP (\(rows)) a.object_id, REPLICATE('x', 100) AS pad FROM sys.all_columns a CROSS JOIN sys.all_columns b"
    }

    final class Settled<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?

        func record(_ result: Result<Value, Error>) { lock.withLock { self.result = result } }
        var value: Result<Value, Error>? { lock.withLock { result } }
    }

    /// Waits for `task` for at most `seconds` without depending on it ever ending: a read the driver lost stays blocked
    /// inside db-lib for good, and the checks after it still have to run. Nil when it did not end in time.
    static func settle<Value: Sendable>(_ task: Task<Value, Error>, within seconds: Double) async -> Result<Value, Error>? {
        let settled = Settled<Value>()
        Task.detached { settled.record(await task.result) }
        let deadline = Date().addingTimeInterval(seconds)
        while settled.value == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return settled.value
    }

    /// A Stop pressed on a thread of its own. The app presses it on the main thread and waits for it to return, so a
    /// Stop that never returns freezes the app; pressing it here keeps a Stop that blocks from holding up the checks.
    final class StopPress: @unchecked Sendable {
        private let lock = NSLock()
        private var hasReturned = false

        func markReturned() { lock.withLock { hasReturned = true } }

        func returns(within seconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !lock.withLock({ hasReturned }), Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return lock.withLock { hasReturned }
        }
    }

    static func pressStop(_ driver: MSSQLPluginDriver) -> StopPress {
        let press = StopPress()
        Thread.detachNewThread {
            try? driver.cancelQuery()
            press.markReturned()
        }
        return press
    }

    static func answersPromptly(_ driver: MSSQLPluginDriver) async -> Bool {
        let probe = Task { try await driver.execute(query: "SELECT 42 AS n").rows.first?.first?.asText }
        guard case .success(let answer)? = await settle(probe, within: 5) else { return false }
        return answer == "42"
    }

    static func runningRequests(of spid: String, seenBy observer: MSSQLPluginDriver) async throws -> String? {
        let requests = try await observer.execute(
            query: "SELECT COUNT(*) AS n FROM sys.dm_exec_requests WHERE session_id = \(Int(spid) ?? -1)"
        )
        return requests.rows.first?.first?.asText
    }

    static func connect(_ database: String) async throws -> MSSQLPluginDriver {
        let environment = ProcessInfo.processInfo.environment
        let config = DriverConnectionConfig(
            host: environment["TP_CHECK_HOST"] ?? "127.0.0.1",
            port: Int(environment["TP_CHECK_PORT"] ?? "") ?? 1433,
            username: environment["TP_CHECK_USER"] ?? "sa",
            password: environment["TP_CHECK_PASSWORD"] ?? "",
            database: database
        )
        let deadline = Date().addingTimeInterval(120)
        while true {
            let driver = MSSQLPluginDriver(config: config)
            do {
                try await driver.connect()
                return driver
            } catch where Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            try await run()
        } catch {
            failures += 1
            print("FAIL: unexpected error \(error)")
        }
        print(failures == 0 ? "OK: every check passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func run() async throws {
        let admin = try await connect("master")
        _ = try await admin.execute(query: "IF DB_ID(N'\(database)') IS NULL CREATE DATABASE [\(database)]")
        admin.disconnect()

        let driver = try await connect(database)
        _ = try await driver.executeBatch(query: """
            IF OBJECT_ID(N'dbo.serialnew') IS NULL CREATE TABLE dbo.serialnew ([S/N] NVARCHAR(50), model NVARCHAR(20));
            IF OBJECT_ID(N'dbo.wms') IS NULL CREATE TABLE dbo.wms ([S/N] NVARCHAR(50), bin_code NVARCHAR(10), qty INT, model NVARCHAR(20));
            IF OBJECT_ID(N'dbo.drm_report_n') IS NULL CREATE TABLE dbo.drm_report_n ([Serial number] NVARCHAR(50), status NVARCHAR(10));
            IF OBJECT_ID(N'dbo.serial_existed') IS NULL CREATE TABLE dbo.serial_existed (sn_code NVARCHAR(50), seen_at DATETIME2);
            IF OBJECT_ID(N'dbo.pk_check') IS NULL CREATE TABLE dbo.pk_check (id INT PRIMARY KEY);
            IF OBJECT_ID(N'dbo.update_check') IS NULL CREATE TABLE dbo.update_check (id INT, v NVARCHAR(10));
            IF OBJECT_ID(N'dbo.capped_rows') IS NULL BEGIN
                CREATE TABLE dbo.capped_rows (id INT PRIMARY KEY, pad CHAR(100) NOT NULL DEFAULT 'x');
                INSERT INTO dbo.capped_rows (id)
                    SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b;
            END;
            IF OBJECT_ID(N'dbo.stop_locked') IS NULL BEGIN
                CREATE TABLE dbo.stop_locked (id INT PRIMARY KEY);
                INSERT INTO dbo.stop_locked SELECT TOP (5000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns;
            END;
            IF OBJECT_ID(N'dbo.stop_disconnect') IS NULL CREATE TABLE dbo.stop_disconnect (id INT);
            """, rowCap: nil, parameters: nil)
        _ = try await driver.executeBatch(query: """
            DELETE FROM dbo.serialnew; DELETE FROM dbo.wms; DELETE FROM dbo.drm_report_n; DELETE FROM dbo.serial_existed;
            DELETE FROM dbo.pk_check; DELETE FROM dbo.update_check;
            INSERT INTO dbo.update_check VALUES (1, N'a'), (2, N'b'), (3, N'c');
            INSERT INTO dbo.serialnew VALUES (N'2404GQV000066A00105', N'M1');
            INSERT INTO dbo.wms VALUES (N'2404GQV000066A00105', N'B1', 3, N'M1'), (N'2404GQV000066A00105', N'B2', 4, N'M1');
            INSERT INTO dbo.serial_existed VALUES (N'2404GQV000066A00105', SYSDATETIME());
            INSERT INTO dbo.pk_check VALUES (1);
            """, rowCap: nil, parameters: nil)

        try await reporterScript(driver)
        try await errorBetweenResultSets(driver)
        try await singleResultErrors(driver)
        try await laterResultSets(driver)
        try await rowCaps(driver)
        try await procedureResultSets(driver)
        try await serverOutput(driver)
        try await counts(driver)
        try await parameterNames(driver)
        try await boundCountsAndCalls(driver)
        try await manyErrors(driver)

        let observer = try await connect(database)
        try await cappedReadsEndTheirStatement(driver, observer: observer)
        try await stopDuringWaitfor()
        try await stopDuringLargeResult()
        try await stopDuringBlockedRead(locker: observer)
        try await stopWhileReadingPastTheRest(observer: observer)
        try await disconnectEndsTheStatement(observer: observer)
        observer.disconnect()
        try await fatalError(driver)
    }

    static func reporterScript(_ driver: MSSQLPluginDriver) async throws {
        let batch = """
            DECLARE @sn NVARCHAR(50) = '2404GQV000066A00105';

            SELECT * FROM serialnew WHERE [S/N] = @sn;
            SELECT * FROM [wms] WHERE [S/N] = @sn;
            SELECT * FROM drm_report_n WHERE [Serial number] = @sn;
            SELECT * FROM serial_existed WHERE sn_code = @sn;
            """
        guard let result = try await driver.executeBatch(query: batch, rowCap: nil, parameters: nil) else {
            expect(false, "the reporter's script runs as one batch", "executeBatch returned nil")
            return
        }
        expect(result.errors.isEmpty, "the reporter's script raises no error", "\(result.errors)")
        expect(
            result.resultSets.map(columns) == [
                ["S/N", "model"], ["S/N", "bin_code", "qty", "model"], ["Serial number", "status"], ["sn_code", "seen_at"],
            ],
            "the reporter's script returns 4 result sets, each with its own columns",
            "\(result.resultSets.map(columns))"
        )
        expect(result.resultSets.map(\.rows.count) == [1, 2, 0, 1], "each result set keeps its own rows",
               "\(result.resultSets.map(\.rows.count))")
    }

    static func errorBetweenResultSets(_ driver: MSSQLPluginDriver) async throws {
        let result = try await driver.executeBatch(
            query: "SELECT 1 AS one;\nINSERT INTO dbo.pk_check VALUES (1);\nSELECT 3 AS three;",
            rowCap: nil,
            parameters: nil
        )
        expect(result?.resultSets.map(columns) == [["one"], ["three"]], "a batch goes on past a failed statement",
               "\(String(describing: result?.resultSets.map(columns)))")
        let error = result?.errors.first
        expect(error?.code == 2627 && error?.line == 2 && error?.precedingResultSetCount == 1,
               "the error is 2627 on line 2, after the first result set", "\(String(describing: result?.errors))")
        let followUp = try await driver.execute(query: "SELECT 1 AS n")
        expect(followUp.rows.count == 1, "the connection answers the next query")

        let failedFirst = try await driver.executeBatch(
            query: "INSERT INTO dbo.pk_check VALUES (1);\nSELECT 3 AS three;\nSELECT 4 AS four;",
            rowCap: nil,
            parameters: nil
        )
        expect(failedFirst?.resultSets.map(columns) == [["three"], ["four"]],
               "a failure in the first statement keeps the results after it",
               "\(String(describing: failedFirst?.resultSets.map(columns)))")
        let second = try await driver.execute(query: "SELECT 2 AS n")
        expect(second.rows.first?.first?.asText == "2", "the connection is clean after a failed first statement")
    }

    static func singleResultErrors(_ driver: MSSQLPluginDriver) async throws {
        do {
            _ = try await driver.execute(query: "SELECT 1/0 AS z")
            expect(false, "SELECT 1/0 fails on the single-result path")
        } catch {
            expect("\(error.localizedDescription)".contains("Divide by zero"), "SELECT 1/0 fails on the single-result path",
                   error.localizedDescription)
        }
        do {
            _ = try await driver.execute(query: "SELECT CAST(v AS INT) AS n FROM (VALUES ('1'),('2'),('x'),('4')) AS t(v)")
            expect(false, "a conversion error in the middle of a scan fails the read")
        } catch {
            expect(error.localizedDescription.contains("Conversion failed"),
                   "a conversion error in the middle of a scan fails the read", error.localizedDescription)
        }
        do {
            _ = try await driver.execute(query: "SELECT 1 AS a SELECT * FROM no_such_table_check")
            expect(false, "an error after a result set reports the server's message")
        } catch {
            expect(error.localizedDescription.contains("no_such_table_check"),
                   "an error after a result set reports the server's message", error.localizedDescription)
        }
        let after = try await driver.execute(query: "SELECT 5 AS n")
        expect(after.rows.first?.first?.asText == "5", "the connection answers after single-result errors")
    }

    static func laterResultSets(_ driver: MSSQLPluginDriver) async throws {
        let text = "SELECT 1 AS a\nSELECT 1 AS x, 2 AS y, 3 AS z"
        let bounded = try await driver.executeBoundedQuery(query: text, rowCap: 100)
        expect(bounded?.columns == ["a"], "a wider later result set does not reach the bounded read",
               "\(String(describing: bounded?.columns))")
        expect(bounded?.statusMessage?.contains("2") == true, "the bounded read says a result set was not shown",
               "\(String(describing: bounded?.statusMessage))")

        var headers: [[String]] = []
        var rowCount = 0
        for try await element in driver.streamRows(query: text) {
            switch element {
            case .header(let header): headers.append(header.columns)
            case .rows(let rows): rowCount += rows.count
            }
        }
        expect(headers == [["a"]] && rowCount == 1, "the stream sends one header and the first result set's rows",
               "headers=\(headers) rows=\(rowCount)")
    }

    static func rowCaps(_ driver: MSSQLPluginDriver) async throws {
        let batch = "SELECT TOP (50) a.object_id FROM sys.all_columns a;\nSELECT 42 AS later;"
        let result = try await driver.executeBatch(query: batch, rowCap: 10, parameters: nil)
        expect(result?.resultSets.first?.rows.count == 10 && result?.resultSets.first?.isTruncated == true,
               "a capped result set stops at the cap and says so")
        expect(result?.resultSets.last?.columns == ["later"], "a result set after a capped one still arrives")

        _ = try await driver.executeBatch(
            query: "SET XACT_ABORT ON; BEGIN TRAN; INSERT INTO dbo.pk_check VALUES (77);",
            rowCap: nil,
            parameters: nil
        )
        let bounded = try await driver.executeBoundedQuery(query: crossJoin(rows: 200_000), rowCap: 10_000)
        expect(bounded?.rows.count == 10_000 && bounded?.isTruncated == true, "a bounded read stops at its cap")
        let after = try await driver.execute(query: "SELECT @@TRANCOUNT AS open_transactions, COUNT(*) AS kept FROM dbo.pk_check WHERE id = 77")
        expect(after.rows.first?.map(\.asText) == ["1", "1"],
               "a capped read leaves an open XACT_ABORT transaction and its work in place",
               "\(String(describing: after.rows.first?.map(\.asText)))")
        _ = try await driver.execute(query: "IF @@TRANCOUNT > 0 ROLLBACK; SET XACT_ABORT OFF")
        let next = try await driver.execute(query: "SELECT 7 AS n")
        expect(next.rows.first?.first?.asText == "7", "the query after a capped read answers with its own result")
    }

    static func cappedReadsEndTheirStatement(_ driver: MSSQLPluginDriver, observer: MSSQLPluginDriver) async throws {
        let spid = try await driver.execute(query: "SELECT @@SPID AS spid").rows.first?.first?.asText ?? ""
        let alter = "SET LOCK_TIMEOUT 3000; ALTER TABLE dbo.capped_rows ADD capped_probe INT NULL; "
            + "ALTER TABLE dbo.capped_rows DROP COLUMN capped_probe; SET LOCK_TIMEOUT -1;"

        let capped = try await driver.executeBoundedQuery(query: "SELECT * FROM dbo.capped_rows", rowCap: 10_000)
        expect(capped?.rows.count == 10_000 && capped?.isTruncated == true, "a capped read of a table keeps 10,000 rows")
        let running = try await runningRequests(of: spid, seenBy: observer)
        expect(running == "0", "a capped read leaves no statement running on the server", "requests=\(running ?? "nil")")
        let altered = try await observer.executeBatch(query: alter, rowCap: nil, parameters: nil)
        expect(altered?.errors.isEmpty == true, "a capped read releases its locks: another session alters the table",
               "\(String(describing: altered?.errors.map(\.message)))")

        _ = try await driver.executeBatch(
            query: "BEGIN TRAN; INSERT INTO dbo.pk_check VALUES (78);", rowCap: nil, parameters: nil
        )
        _ = try await driver.executeBoundedQuery(query: "SELECT * FROM dbo.capped_rows", rowCap: 10_000)
        let alteredInTransaction = try await observer.executeBatch(query: alter, rowCap: nil, parameters: nil)
        let kept = try await driver.execute(query: "SELECT @@TRANCOUNT AS open_transactions, COUNT(*) AS kept FROM dbo.pk_check WHERE id = 78")
        expect(alteredInTransaction?.errors.isEmpty == true && kept.rows.first?.map(\.asText) == ["1", "1"],
               "without XACT_ABORT a capped read in a transaction ends its SELECT and keeps the transaction and its work",
               "\(String(describing: alteredInTransaction?.errors.map(\.message))) \(String(describing: kept.rows.first?.map(\.asText)))")
        _ = try await driver.execute(query: "IF @@TRANCOUNT > 0 ROLLBACK")

        _ = try await driver.executeBatch(
            query: "SET XACT_ABORT ON; BEGIN TRAN; INSERT INTO dbo.pk_check VALUES (77);", rowCap: nil, parameters: nil
        )
        _ = try await driver.executeBoundedQuery(query: "SELECT * FROM dbo.capped_rows", rowCap: 10_000)
        let runningInTransaction = try await runningRequests(of: spid, seenBy: observer)
        let keptUnderXactAbort = try await driver.execute(query: "SELECT @@TRANCOUNT AS open_transactions, COUNT(*) AS kept FROM dbo.pk_check WHERE id = 77")
        expect(runningInTransaction == "0" && keptUnderXactAbort.rows.first?.map(\.asText) == ["1", "1"],
               "under XACT_ABORT a capped read reads the rest in its own call: nothing left running, the transaction kept",
               "requests=\(runningInTransaction ?? "nil") \(String(describing: keptUnderXactAbort.rows.first?.map(\.asText)))")
        _ = try await driver.execute(query: "IF @@TRANCOUNT > 0 ROLLBACK; SET XACT_ABORT OFF")

        _ = try await driver.executeBoundedQuery(query: crossJoin(rows: 5_000_000), rowCap: 10_000)
        let startedAt = Date()
        let next = try await driver.execute(query: "SELECT 7 AS n")
        let answeredIn = Date().timeIntervalSince(startedAt)
        expect(next.rows.first?.first?.asText == "7" && answeredIn < 2,
               "the query after a capped read of 5,000,000 rows answers at once",
               String(format: "%.2fs", answeredIn))
    }

    /// What went wrong when Stop was pressed on `read` after `delay`, or nothing. The Stop has to come back at once,
    /// the read has to end with an error within 3 seconds, and the connection has to answer the next query.
    static func stopMisses(
        _ driver: MSSQLPluginDriver,
        after delay: UInt64,
        read: Task<Void, Error>
    ) async throws -> [String] {
        try await Task.sleep(nanoseconds: delay)
        let stoppedAt = Date()
        let press = pressStop(driver)
        let outcome = await settle(read, within: 10)
        let endedIn = Date().timeIntervalSince(stoppedAt)
        var misses: [String] = []
        if await !press.returns(within: 2) {
            misses.append("the Stop never returned")
        }
        switch outcome {
        case nil:
            misses.append("the read never ended")
        case .success?:
            misses.append("the read finished instead of stopping")
        case .failure?:
            if endedIn >= 3 { misses.append(String(format: "the read ended %.2fs after the Stop", endedIn)) }
            if await !answersPromptly(driver) { misses.append("the connection did not answer after") }
        }
        return misses
    }

    /// Runs a Stop scenario `attempts` times on a fresh connection each time. A Stop that reads the socket from its
    /// own thread races the thread reading the connection, so one attempt that happened to win proves nothing.
    static func expectStop(
        _ label: String,
        attempts: Int = 3,
        _ attempt: (MSSQLPluginDriver) async throws -> [String]
    ) async throws {
        var misses: [String] = []
        for number in 1...attempts {
            let driver = try await connect(database)
            let missed = try await attempt(driver)
            if !missed.isEmpty {
                misses.append("attempt \(number): \(missed.joined(separator: ", "))")
            }
            driver.disconnect()
        }
        expect(misses.isEmpty, label, misses.joined(separator: "; "))
    }

    static func stopDuringWaitfor() async throws {
        try await expectStop("a Stop during a WAITFOR returns, ends the call and leaves the connection answering") { driver in
            let read = Task {
                _ = try await driver.executeBatch(query: "WAITFOR DELAY '00:00:30'; SELECT 1 AS n;", rowCap: nil, parameters: nil)
            }
            return try await stopMisses(driver, after: 700_000_000, read: read)
        }
    }

    static func stopDuringLargeResult() async throws {
        try await expectStop("a Stop during a large result returns, ends the call and leaves the connection answering") { driver in
            let read = Task {
                _ = try await driver.executeBatch(query: crossJoin(rows: 30_000_000), rowCap: nil, parameters: nil)
            }
            return try await stopMisses(driver, after: 700_000_000, read: read)
        }
    }

    static func stopDuringBlockedRead(locker: MSSQLPluginDriver) async throws {
        try await expectStop(
            "a Stop during a read blocked on another session's lock returns, ends the call and leaves the connection answering"
        ) { driver in
            _ = try await locker.executeBatch(
                query: "BEGIN TRAN; UPDATE dbo.stop_locked SET id = id WHERE id = 4000;", rowCap: nil, parameters: nil
            )
            let read = Task {
                _ = try await driver.executeBatch(query: "SELECT id FROM dbo.stop_locked ORDER BY id;", rowCap: nil, parameters: nil)
            }
            let misses = try await stopMisses(driver, after: 1_500_000_000, read: read)
            _ = try await locker.execute(query: "IF @@TRANCOUNT > 0 ROLLBACK")
            return misses
        }
    }

    static func stopWhileReadingPastTheRest(observer: MSSQLPluginDriver) async throws {
        let driver = try await connect(database)
        _ = try await driver.executeBatch(
            query: "SET XACT_ABORT ON; BEGIN TRAN; INSERT INTO dbo.pk_check VALUES (79);", rowCap: nil, parameters: nil
        )
        let read = Task { try await driver.executeBoundedQuery(query: crossJoin(rows: 5_000_000), rowCap: 10_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let delete = Task { try await driver.executeBatch(query: "DELETE FROM dbo.pk_check WHERE id = 1;", rowCap: nil, parameters: nil) }
        try await Task.sleep(nanoseconds: 700_000_000)
        let stoppedAt = Date()
        let press = pressStop(driver)
        let readOutcome = await settle(read, within: 10)
        let deleteOutcome = await settle(delete, within: 10)
        let answeredIn = Date().timeIntervalSince(stoppedAt)
        let stopReturned = await press.returns(within: 2)
        let readStopped: Bool
        if case .failure? = readOutcome { readStopped = true } else { readStopped = false }
        let deleteStopped: Bool
        if case .failure? = deleteOutcome { deleteStopped = true } else { deleteStopped = false }
        expect(stopReturned && readStopped && deleteStopped && answeredIn < 3,
               "a Stop while a capped read reads past the rest ends it and the statement queued behind it",
               String(format: "stop=%@ read=%@ delete=%@ after %.2fs", stopReturned ? "returned" : "never returned",
                      readStopped ? "stopped" : "not stopped", deleteStopped ? "stopped" : "not stopped", answeredIn))
        let kept = try await observer.execute(query: "SELECT COUNT(*) AS n FROM dbo.pk_check WHERE id = 1")
        expect(kept.rows.first?.first?.asText == "1", "the statement queued behind the Stop was never sent: the row is still there",
               "\(String(describing: kept.rows.first?.first?.asText))")
        guard readOutcome != nil, deleteOutcome != nil else { return }
        _ = try? await driver.execute(query: "IF @@TRANCOUNT > 0 ROLLBACK; SET XACT_ABORT OFF")
        expect(await answersPromptly(driver), "the connection answers after a Stop while reading past the rest")
        driver.disconnect()
    }

    static func disconnectEndsTheStatement(observer: MSSQLPluginDriver) async throws {
        let closingWindow = try await disconnectMisses(observer: observer) { driver in
            let press = pressStop(driver)
            let stopReturned = await press.returns(within: 1)
            driver.disconnect()
            return stopReturned ? [] : ["the Stop never returned"]
        }
        expect(closingWindow.isEmpty, "a Stop and then a disconnect, as closing a window does, end the statement on the server",
               closingWindow.joined(separator: ", "))

        let disconnecting = try await disconnectMisses(observer: observer) { driver in
            driver.disconnect()
            return []
        }
        expect(disconnecting.isEmpty, "a disconnect alone, as Disconnect does before any Stop, ends the statement on the server",
               disconnecting.joined(separator: ", "))
    }

    /// What was wrong once `end` ran 1 second into a WAITFOR and an INSERT, or nothing. The read has to end, the session
    /// has to be gone from the server within 3 seconds, and nothing may be written once the WAITFOR would have ended.
    static func disconnectMisses(
        observer: MSSQLPluginDriver,
        end: (MSSQLPluginDriver) async -> [String]
    ) async throws -> [String] {
        _ = try await observer.execute(query: "DELETE FROM dbo.stop_disconnect")
        let driver = try await connect(database)
        let identity = try await driver.execute(
            query: "SELECT @@SPID AS spid, CONVERT(VARCHAR(30), login_time, 121) AS login FROM sys.dm_exec_sessions WHERE session_id = @@SPID"
        ).rows.first?.map(\.asText)
        guard let identity, identity.count == 2, let spid = identity[0], let login = identity[1] else {
            return ["the session could not be identified"]
        }
        let startedAt = Date()
        let read = Task {
            _ = try await driver.executeBatch(
                query: "WAITFOR DELAY '00:00:06'; INSERT INTO dbo.stop_disconnect VALUES (1);", rowCap: nil, parameters: nil
            )
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var misses = await end(driver)
        let endedAt = Date()

        let sessionQuery = "SELECT COUNT(*) AS n FROM sys.dm_exec_sessions WHERE session_id = \(Int(spid) ?? -1) "
            + "AND CONVERT(VARCHAR(30), login_time, 121) = '\(login)'"
        var sessionClosed = false
        while !sessionClosed, Date().timeIntervalSince(endedAt) < 3 {
            sessionClosed = try await observer.execute(query: sessionQuery).rows.first?.first?.asText == "0"
            if !sessionClosed { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        if !sessionClosed { misses.append("the session was still on the server 3s later") }
        switch await settle(read, within: 1) {
        case nil: misses.append("the read never ended")
        case .success?: misses.append("the read finished instead of stopping")
        case .failure?: break
        }

        let waitforEnd = startedAt.addingTimeInterval(8)
        if Date() < waitforEnd {
            try await Task.sleep(nanoseconds: UInt64(waitforEnd.timeIntervalSinceNow * 1_000_000_000))
        }
        let written = try await observer.execute(query: "SELECT COUNT(*) AS n FROM dbo.stop_disconnect").rows.first?.first?.asText
        if written != "0" { misses.append("the INSERT behind the WAITFOR wrote \(written ?? "nil") row(s)") }
        return misses
    }

    static func procedureResultSets(_ driver: MSSQLPluginDriver) async throws {
        let result = try await driver.executeBatch(query: "EXEC sp_help 'dbo.pk_check'", rowCap: nil, parameters: nil)
        let widths = result?.resultSets.map(\.columns.count) ?? []
        expect(widths.count >= 3 && Set(widths).count > 1, "EXEC sp_help returns its result sets with their own columns",
               "\(widths)")
    }

    static func serverOutput(_ driver: MSSQLPluginDriver) async throws {
        _ = try await driver.execute(query: "PRINT 'hello from print'; SELECT 1 AS a")
        let output = try await driver.fetchServerOutput()
        expect(output.lines == ["hello from print"], "PRINT reaches the server output", "\(output.lines)")
        let again = try await driver.fetchServerOutput()
        expect(again.lines.isEmpty, "the server output is handed over once", "\(again.lines)")
        _ = try await driver.execute(query: "USE [\(database)]")
        let context = try await driver.fetchServerOutput()
        expect(context.lines.isEmpty, "a change of database context is not output", "\(context.lines)")
    }

    static func counts(_ driver: MSSQLPluginDriver) async throws {
        let created = try await driver.execute(query: "CREATE TABLE #counted (id INT)")
        expect(created.rowsAffected == 0, "a statement that reports no count affects 0 rows, not -1",
               "\(created.rowsAffected)")
        let inserted = try await driver.executeBatch(
            query: "INSERT INTO #counted VALUES (1), (2), (3); UPDATE #counted SET id = id + 1 WHERE id > 1;",
            rowCap: nil,
            parameters: nil
        )
        expect(inserted?.rowsAffected == 5, "counts add up across a batch", "\(String(describing: inserted?.rowsAffected))")
    }

    static func parameterNames(_ driver: MSSQLPluginDriver) async throws {
        let result = try await driver.executeBatch(
            query: "DECLARE @p1 INT = 5;\nSELECT @p1 AS v, ? AS w;",
            rowCap: nil,
            parameters: [.text("x")]
        )
        expect(result?.errors.isEmpty == true && result?.resultSets.first?.columns == ["v", "w"],
               "a batch that declares @p1 still binds its parameters", "\(String(describing: result?.errors))")
        let inside = try await driver.executeBatch(
            query: "SELECT ? AS a;\nSELECT 1/0 AS b;",
            rowCap: nil,
            parameters: [.text("x")]
        )
        expect(inside?.errors.first?.line == 2, "an error inside a parameterized batch keeps its line",
               "\(String(describing: inside?.errors))")
        let multiline = try await driver.executeBatch(
            query: "SELECT ? AS a;\nSELECT 1/0 AS b;",
            rowCap: nil,
            parameters: [.text("first\nsecond\r\nthird")]
        )
        expect(multiline?.errors.first?.line == 2, "a value holding line feeds does not move the reported line",
               "\(String(describing: multiline?.errors))")

        let transaction = try await driver.executeBatch(
            query: "BEGIN TRAN;\nUPDATE dbo.pk_check SET id = id WHERE id = ?;",
            rowCap: nil,
            parameters: [.text("1")]
        )
        let open = try await driver.execute(query: "SELECT @@TRANCOUNT AS n")
        expect(transaction?.errors.isEmpty == true && open.rows.first?.first?.asText == "1",
               "a parameterized batch that opens a transaction leaves it open with no Msg 266",
               "\(String(describing: transaction?.errors)) trancount=\(String(describing: open.rows.first?.first?.asText))")
        _ = try await driver.execute(query: "IF @@TRANCOUNT > 0 ROLLBACK")

        _ = try await driver.executeBatch(
            query: "IF OBJECT_ID('tempdb..#stage') IS NOT NULL DROP TABLE #stage;\n"
                + "CREATE TABLE #stage (v NVARCHAR(10));\nINSERT INTO #stage VALUES (?);",
            rowCap: nil,
            parameters: [.text("staged")]
        )
        let staged = try await driver.executeBatch(query: "SELECT v FROM #stage;", rowCap: nil, parameters: nil)
        expect(staged?.resultSets.first?.rows.first?.first?.asText == "staged",
               "a #temp table made in a parameterized batch outlives it", "\(String(describing: staged?.errors))")
    }

    static func boundCountsAndCalls(_ driver: MSSQLPluginDriver) async throws {
        let updated = try await driver.executeBatch(
            query: "UPDATE dbo.update_check SET v = ?;", rowCap: nil, parameters: [.text("z")]
        )
        expect(updated?.rowsAffected == 3, "a parameterized UPDATE of 3 rows reports 3",
               "\(String(describing: updated?.rowsAffected))")
        let none = try await driver.executeBatch(
            query: "UPDATE dbo.update_check SET v = N'y' WHERE id = ?;", rowCap: nil, parameters: [.text("999")]
        )
        expect(none?.rowsAffected == 0, "a parameterized UPDATE that matches nothing reports 0",
               "\(String(describing: none?.rowsAffected))")
        let call = try await driver.executeBatch(query: "sp_help ?", rowCap: nil, parameters: [.text("dbo.pk_check")])
        expect(call?.errors.isEmpty == true && (call?.resultSets.count ?? 0) >= 3,
               "a procedure called without EXEC still binds its parameters", "\(String(describing: call?.errors))")
    }

    static func manyErrors(_ driver: MSSQLPluginDriver) async throws {
        let batch = """
            DECLARE @i INT = 0;
            WHILE @i < 1500 BEGIN RAISERROR('loop error %d', 16, 1, @i); SET @i += 1; END;
            SELECT 'after loop' AS done;
            """
        let result = try await driver.executeBatch(query: batch, rowCap: nil, parameters: nil)
        expect(result?.resultSets.map(columns) == [["done"]], "a batch raising 1,500 errors still returns what follows",
               "\(String(describing: result?.resultSets.map(columns)))")
        expect(result?.errors.count == 1_001 && result?.errors.last?.message.contains("500") == true,
               "the errors past the kept ones are counted", "\(String(describing: result?.errors.last))")
        let after = try await driver.execute(query: "SELECT 8 AS n")
        expect(after.rows.first?.first?.asText == "8", "the connection answers after 1,500 errors")
    }

    static func fatalError(_ driver: MSSQLPluginDriver) async throws {
        do {
            _ = try await driver.executeBatch(query: "RAISERROR('fatal check', 20, 1) WITH LOG", rowCap: nil, parameters: nil)
            expect(false, "a severity 20 error fails the batch as a lost connection")
        } catch {
            expect(error.localizedDescription.contains("fatal check"), "a severity 20 error fails the batch as a lost connection",
                   error.localizedDescription)
        }
        driver.disconnect()
    }
}
SWIFT

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
swift build --package-path "$WORK" --scratch-path "$WORK/.build" > "$WORK/build.log" 2>&1 || {
    echo "the check failed to build" >&2
    grep -E "error:" "$WORK/build.log" >&2
    exit 3
}

TP_CHECK_HOST="$HOST" TP_CHECK_PORT="$PORT" TP_CHECK_USER="$USER_NAME" TP_CHECK_PASSWORD="$PASSWORD" \
    TP_CHECK_DATABASE="$DATABASE" "$WORK/.build/debug/Check"
