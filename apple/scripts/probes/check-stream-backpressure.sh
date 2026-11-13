#!/usr/bin/env bash
#
# Measure how much memory a driver's row stream holds while its consumer is slower than the source.
#
# Builds a harness from the driver's own sources, fills a table on a real server, then reads it through
# `streamRows` with a consumer that waits per batch, the way a copy waits on its target's inserts. It prints the
# process footprint before the read and its peak during it. A stream with backpressure peaks at a few batches; one
# without it holds every row the consumer has not taken yet.
#
# Usage:
#   scripts/probes/check-stream-backpressure.sh <engine> [--rows N] [--delay-ms N] [--hold-seconds N] [--root DIR]
#
#   engine:     postgresql, mysql, sqlite (a scratch file, no server), sqlite-agent (the same file read through the
#               remote SQLite agent, run by the local python3 behind a loopback relay that stands in for the SSH session)
#   --rows      rows in the probe table, default 1000000
#   --delay-ms  the consumer's wait per batch, default 20
#   --hold-seconds  how long the consumer waits after its first batch, default 0
#   --root      the apple/ folder whose sources to build, default this one; Libs comes from it too
#
# TP_STREAM_HOST, TP_STREAM_PORT, TP_STREAM_USER, TP_STREAM_PASSWORD and TP_STREAM_DATABASE name the server, by
# default a local one on the engine's port as the current user. TP_STREAM_BUILD_DIR keeps the harness between runs.
# For sqlite-agent, TP_STREAM_SSH holds ssh's arguments up to the destination, separated by single spaces with no
# quoting: the agent then runs on that server through the launcher command the app sends. TP_STREAM_DATABASE must then
# name an existing scratch file there; the probe fills it with the table and the file keeps that size afterwards.
# Exits 1 when the read fails, 3 when the probe cannot run.

set -uo pipefail

ENGINE="${1:-}"
shift || true
ROWS=1000000
DELAY_MS=20
HOLD_SECONDS=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT"
while [ $# -gt 0 ]; do
    case "$1" in
        --rows) ROWS="${2:?}"; shift 2 ;;
        --delay-ms) DELAY_MS="${2:?}"; shift 2 ;;
        --hold-seconds) HOLD_SECONDS="${2:?}"; shift 2 ;;
        --root) ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 3 ;;
    esac
done
PLUGINS="$ROOT/Plugins"

case "$ENGINE" in
    postgresql)
        FOLDER=PostgreSQLDriverPlugin CLASS=PostgreSQLPlugin C_MODULE=CLibPQ
        PRODUCTS="TableProCoreTypes TableProGeometry TableProKerberos TableProLogRedaction TableProPostgreSQLCore TableProSQLQuoting TableProSQLVocabulary TableProTLSClientIdentity"
        LINK="$ROOT/Libs/libpq.a $ROOT/Libs/libpgcommon.a $ROOT/Libs/libpgport.a -lssl.3 -lcrypto.3 -lz -framework GSS -lcom_err"
        PORT_DEFAULT=5432 DATABASE_DEFAULT=postgres
        CREATE="CREATE TABLE tp_stream_probe AS SELECT g AS id, repeat(md5(g::text), 6) AS payload FROM generate_series(1, $ROWS) AS g"
        ;;
    mysql)
        FOLDER=MySQLDriverPlugin CLASS=MySQLPlugin C_MODULE=CMariaDB
        PRODUCTS="TableProCoreTypes TableProKerberos TableProLogRedaction TableProMySQLCore TableProSQLQuoting TableProSQLVocabulary"
        LINK="$ROOT/Libs/libmariadb.a -lssl.3 -lcrypto.3 -liconv -lz"
        PORT_DEFAULT=3306 DATABASE_DEFAULT=test
        digits="(SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)"
        CREATE="CREATE TABLE tp_stream_probe AS SELECT id, REPEAT(MD5(id), 6) AS payload FROM (SELECT d0.n + d1.n * 10 + d2.n * 100 + d3.n * 1000 + d4.n * 10000 + d5.n * 100000 + d6.n * 1000000 + 1 AS id FROM $digits d0, $digits d1, $digits d2, $digits d3, $digits d4, $digits d5, $digits d6) AS numbers WHERE id <= $ROWS"
        ;;
    sqlite | sqlite-agent)
        FOLDER=SQLiteDriverPlugin CLASS=SQLitePlugin C_MODULE=""
        PRODUCTS="CSQLite TableProSQLiteCore TableProSQLQuoting TableProSQLVocabulary"
        LINK="$ROOT/Libs/libsqlite3_vendored.a"
        CREATE="CREATE TABLE tp_stream_probe AS WITH RECURSIVE g(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM g WHERE x < $ROWS) SELECT x AS id, hex(randomblob(96)) AS payload FROM g"
        ;;
    *)
        echo "usage: $0 <postgresql|mysql|sqlite|sqlite-agent> [--rows N] [--delay-ms N] [--hold-seconds N] [--root DIR]" >&2
        exit 3
        ;;
esac

command -v swift > /dev/null || { echo "swift not found" >&2; exit 3; }
for library in $LINK; do
    case "$library" in
        /*) [ -f "$library" ] || { echo "not found: $library (run scripts/download-libs.sh)" >&2; exit 3; } ;;
    esac
done

HOST="${TP_STREAM_HOST:-127.0.0.1}"
PORT="${TP_STREAM_PORT:-${PORT_DEFAULT:-0}}"
USER_NAME="${TP_STREAM_USER:-$USER}"
PASSWORD="${TP_STREAM_PASSWORD:-}"
DATABASE="${TP_STREAM_DATABASE:-${DATABASE_DEFAULT:-}}"
if [ -n "$C_MODULE" ]; then
    nc -z "$HOST" "$PORT" > /dev/null 2>&1 || { echo "no server at $HOST:$PORT" >&2; exit 3; }
fi

WORK="${TP_STREAM_BUILD_DIR:-}"
if [ -z "$WORK" ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
fi
SOURCES="$WORK/Sources/Probe"
rm -rf "$SOURCES" "$WORK/CModule"
mkdir -p "$SOURCES"
if [ "$ENGINE" = sqlite-agent ] && [ -n "${TP_STREAM_SSH:-}" ] && [ -z "${TP_STREAM_DATABASE:-}" ]; then
    echo "TP_STREAM_SSH needs TP_STREAM_DATABASE, a scratch file on that server" >&2
    exit 3
fi
if [ "$FOLDER" = SQLiteDriverPlugin ] && [ -z "$DATABASE" ]; then
    DATABASE="$WORK/probe.sqlite"
    rm -f "$DATABASE" "$DATABASE-wal" "$DATABASE-shm"
    # The agent opens a file that exists and never creates one.
    if [ "$ENGINE" = sqlite-agent ]; then : > "$DATABASE"; fi
fi

while IFS= read -r source; do
    ln -s "$source" "$SOURCES/driver_$(basename "$source")"
done < <(find "$PLUGINS/$FOLDER" -name '*.swift' -not -path '*/Tests/*')
for shared in PluginConnectTimeout PluginQueryTimeout PluginURLSessionTaskBox; do
    [ -f "$PLUGINS/Shared/$shared.swift" ] && ln -s "$PLUGINS/Shared/$shared.swift" "$SOURCES/shared_$shared.swift"
done
# The agent program and the relay come from this script's checkout, so --root can name a tree from before the relay.
if [ "$ENGINE" = sqlite-agent ]; then
    for helper in TablePro/Core/RemoteSQLite/RemoteSQLiteAgentSource.swift TablePro/Core/RemoteSQLite/RemoteSQLiteWire.swift \
        Plugins/SQLiteDriverTests/SQLiteAgentLoopback.swift; do
        ln -s "$HERE/$helper" "$SOURCES/agent_$(basename "$helper")"
    done
fi
dependencies='.product(name: "TableProPluginKit", package: "TableProCore"),
                .product(name: "TableProSQLGrammar", package: "TableProCore"),
                .product(name: "TableProProcess", package: "TableProCore"),'
system_target=""
c_flags=""
if [ -n "$C_MODULE" ]; then
    ln -s "$PLUGINS/$FOLDER/$C_MODULE" "$WORK/CModule"
    dependencies="$dependencies
                \"$C_MODULE\","
    system_target=".systemLibrary(name: \"$C_MODULE\", path: \"CModule\"),"
    c_flags=".unsafeFlags([\"-Xcc\", \"-I$PLUGINS/$FOLDER/$C_MODULE/include\"]),"
fi
for product in $PRODUCTS; do
    dependencies="$dependencies
                .product(name: \"$product\", package: \"TableProCore\"),"
done
flags="\"-L$ROOT/Libs\", \"-L$ROOT/Libs/dylibs\", \"-Xlinker\", \"-rpath\", \"-Xlinker\", \"$ROOT/Libs/dylibs\""
for flag in $LINK; do
    flags="$flags, \"$flag\""
done

cat > "$WORK/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamBackpressureProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$ROOT/Packages/TableProCore"),
    ],
    targets: [
        $system_target
        .executableTarget(
            name: "Probe",
            dependencies: [
                $dependencies
            ],
            path: "Sources/Probe",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("MemberImportVisibility"),
                $c_flags
            ],
            linkerSettings: [.unsafeFlags([$flags])]
        ),
    ]
)
MANIFEST

if [ "$ENGINE" = sqlite-agent ]; then
    cat > "$SOURCES/probe_Engine.swift" << 'SWIFT'
import Foundation
import TableProPluginKit

typealias EnginePlugin = SQLitePlugin

enum ProbeEndpoint {
    static func config(host: String, port: Int, username: String, password: String, database: String) throws -> DriverConnectionConfig {
        let ssh = ProcessInfo.processInfo.environment["TP_STREAM_SSH"].map { $0.split(separator: " ").map(String.init) }
        let loopback = try ssh.map {
            // -T: no pty, as on the app's exec channel; a pty would rewrite the binary frames.
            try SQLiteAgentLoopback(
                arguments: ["-T"] + $0 + [RemoteSQLiteAgentSource.launcherCommand()], executable: "/usr/bin/ssh", showsErrors: true
            )
        } ?? SQLiteAgentLoopback()
        return DriverConnectionConfig(
            host: "127.0.0.1", port: loopback.port, username: "", password: "", database: database,
            additionalFields: [
                SQLiteAgentProtocol.backendFieldKey: SQLiteAgentProtocol.agentBackendValue,
                SQLiteAgentProtocol.tokenFieldKey: loopback.token,
            ]
        )
    }
}
SWIFT
else
    cat > "$SOURCES/probe_Engine.swift" << SWIFT
import TableProPluginKit

typealias EnginePlugin = $CLASS

enum ProbeEndpoint {
    static func config(host: String, port: Int, username: String, password: String, database: String) throws -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: host, port: port, username: username, password: password, database: database, additionalFields: [:]
        )
    }
}
SWIFT
fi

cat > "$SOURCES/probe_Probe.swift" << 'SWIFT'
import Darwin
import Foundation
import TableProPluginKit

@main
enum Probe {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 9, let delay = Int(arguments[7]), let hold = Int(arguments[8]) else {
            print("usage: Probe <host> <port> <user> <password> <database> <create sql> <delay ms> <hold seconds>")
            exit(3)
        }
        let config: DriverConnectionConfig
        do {
            config = try ProbeEndpoint.config(
                host: arguments[1], port: Int(arguments[2]) ?? 0, username: arguments[3], password: arguments[4],
                database: arguments[5]
            )
        } catch {
            print("cannot reach the engine: \(error)")
            exit(3)
        }
        let driver = EnginePlugin().createDriver(config: config)
        do {
            try await driver.connect()
            try await driver.applyQueryTimeout(0)
            _ = try await driver.execute(query: "DROP TABLE IF EXISTS tp_stream_probe")
            _ = try await driver.execute(query: arguments[6])
        } catch {
            print("cannot prepare the table: \(error)")
            exit(3)
        }

        let sampler = FootprintSampler()
        let baseline = sampler.start()
        let started = Date()
        var rows = 0
        var batches = 0
        var failure: Error?
        do {
            for try await element in driver.streamRows(query: "SELECT id, payload FROM tp_stream_probe ORDER BY id") {
                guard case .rows(let batch) = element else { continue }
                rows += batch.count
                batches += 1
                try await Task.sleep(for: .milliseconds(batches == 1 ? delay + hold * 1_000 : delay))
            }
        } catch {
            failure = error
        }
        let peak = sampler.stop()
        _ = try? await driver.execute(query: "DROP TABLE tp_stream_probe")
        driver.disconnect()

        let megabytes = { (bytes: UInt64) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        print("rows read:          \(rows) in \(batches) batches, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        print("footprint before:   \(megabytes(baseline))")
        print("footprint peak:     \(megabytes(peak))")
        print("peak over baseline: \(megabytes(peak > baseline ? peak - baseline : 0))")
        if let failure {
            print("read failed: \(failure)")
            exit(1)
        }
    }
}

final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = false

    func start() -> UInt64 {
        let baseline = Self.footprint()
        lock.withLock {
            peak = baseline
            running = true
        }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = Self.footprint()
                lock.withLock { peak = max(peak, now) }
                usleep(10_000)
            }
        }
        return baseline
    }

    func stop() -> UInt64 {
        let now = Self.footprint()
        return lock.withLock {
            running = false
            return max(peak, now)
        }
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
SWIFT

echo "building the $ENGINE harness from $ROOT (the first build takes a few minutes)"
(cd "$WORK" && swift build -c release > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -30 >&2
    exit 3
}
"$WORK/.build/release/Probe" "$HOST" "$PORT" "$USER_NAME" "$PASSWORD" "$DATABASE" "$CREATE" "$DELAY_MS" "$HOLD_SECONDS"
