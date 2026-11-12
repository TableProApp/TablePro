#!/usr/bin/env bash
#
# Read a large result through a driver's `streamRows` the way a copy does, against a real server whose idle limit
# ends a read nobody reads from, and print the memory it held and whether the read survived its reader's pause.
#
# Builds a harness from the driver's own sources. `--hold-seconds` reads one batch, then stops reading for that long
# with the stream still held, then reads the rest: a paced stream waits there and has to keep the server's side
# alive. `--delay-us-per-row` makes the reader slower than the server, the way a target's inserts are.
#
# Usage:
#   scripts/probes/check-stream-idle-pacing.sh <engine> [--rows N] [--delay-us-per-row N] [--hold-seconds N] [--root DIR]
#
#   engine:  elasticsearch (fills index tp_stream_probe), mongodb (fills collection tp_stream_probe),
#            trino (reads tpch.sf1.orders, 1.5M rows; --rows adds a LIMIT)
#   --root   the apple/ folder whose driver sources to build, default this one; Libs comes from it too
#
# Servers, with the idle limits scaled down where the server allows it:
#   docker run -d --name tp-es -p 9200:9200 -e discovery.type=single-node -e xpack.security.enabled=false \
#     -e search.keep_alive_interval=5s -e ES_JAVA_OPTS="-Xms1g -Xmx1g" docker.elastic.co/elasticsearch/elasticsearch:8.19.7
#     (the driver keeps its point in time for 1m; the 5 s reaper drops it soon after)
#   docker run -d --name tp-mongo -p 27017:27017 mongo:8.0 --setParameter localLogicalSessionTimeoutMinutes=1 \
#     --setParameter logicalSessionRefreshMillis=1000 --setParameter cursorTimeoutMillis=10000 \
#     --setParameter ttlMonitorSleepSecs=1
#   docker run -d --name tp-trino -p 8080:8080 -v <dir with config.properties>:/etc/trino trinodb/trino
#     (config.properties as the image ships it, plus query.client.timeout=1m)
#
# TP_STREAM_HOST, TP_STREAM_PORT, TP_STREAM_USER and TP_STREAM_PASSWORD name the server, by default 127.0.0.1 on the
# engine's port with no password (user `probe`, none for MongoDB). TP_STREAM_BUILD_DIR keeps the harness between runs. Exits 1 when the read fails, 3 when the probe
# cannot run.

set -uo pipefail

ENGINE="${1:-}"
shift || true
ROWS=1000000
DELAY_US=20
HOLD=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [ $# -gt 0 ]; do
    case "$1" in
        --rows) ROWS="${2:?}"; shift 2 ;;
        --delay-us-per-row) DELAY_US="${2:?}"; shift 2 ;;
        --hold-seconds) HOLD="${2:?}"; shift 2 ;;
        --root) ROOT="$(cd "${2:?}" && pwd)"; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 3 ;;
    esac
done
PLUGINS="$ROOT/Plugins"

C_MODULE=""
LINK=""
case "$ENGINE" in
    elasticsearch)
        FOLDER=ElasticsearchDriverPlugin PORT_DEFAULT=9200
        PRODUCTS="TableProNumberFormatting TableProDocumentPath"
        ;;
    mongodb)
        FOLDER=MongoDBDriverPlugin PORT_DEFAULT=27017 C_MODULE=CLibMongoc
        PRODUCTS="TableProLogRedaction TableProSQLGrammar TableProNumberFormatting"
        LINK="$ROOT/Libs/libmongoc.a $ROOT/Libs/libbson.a -lssl.3 -lcrypto.3 -lresolv -lz"
        ;;
    trino)
        FOLDER=TrinoDriverPlugin PORT_DEFAULT=8080
        PRODUCTS="TableProTLSClientIdentity TableProTrinoCore"
        ;;
    *)
        echo "usage: $0 <elasticsearch|mongodb|trino> [--rows N] [--delay-us-per-row N] [--hold-seconds N] [--root DIR]" >&2
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
PORT="${TP_STREAM_PORT:-$PORT_DEFAULT}"
USER_DEFAULT=probe
[ "$ENGINE" = mongodb ] && USER_DEFAULT=""
USER_NAME="${TP_STREAM_USER:-$USER_DEFAULT}"
PASSWORD="${TP_STREAM_PASSWORD:-}"
nc -z "$HOST" "$PORT" > /dev/null 2>&1 || { echo "no server at $HOST:$PORT" >&2; exit 3; }

WORK="${TP_STREAM_BUILD_DIR:-}"
if [ -z "$WORK" ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
fi
SOURCES="$WORK/Sources/Probe"
rm -rf "$SOURCES" "$WORK/CModule"
mkdir -p "$SOURCES"

while IFS= read -r source; do
    ln -s "$source" "$SOURCES/driver_$(basename "$source")"
done < <(find "$PLUGINS/$FOLDER" -name '*.swift' -not -path '*/Tests/*')
for shared in PluginConnectTimeout PluginQueryTimeout PluginURLSessionTaskBox PluginRedirectRefusingDelegate; do
    [ -f "$PLUGINS/Shared/$shared.swift" ] && ln -s "$PLUGINS/Shared/$shared.swift" "$SOURCES/shared_$shared.swift"
done
dependencies='.product(name: "TableProPluginKit", package: "TableProCore"),
                .product(name: "TableProSQLQuoting", package: "TableProCore"),'
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
    name: "StreamIdlePacingProbe",
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

case "$ENGINE" in
    elasticsearch)
        cat > "$SOURCES/probe_Engine.swift" << 'SWIFT'
import Foundation
import TableProPluginKit

typealias EnginePlugin = ElasticsearchPlugin
let probeFields: [String: String] = [:]
let probeQuery = ElasticsearchOperations.encodeExport(index: "tp_stream_probe")

func fill(_ driver: any PluginDatabaseDriver, rows: Int, host: String, port: Int) async throws {
    let base = "http://\(host):\(port)/tp_stream_probe"
    _ = try? await send("DELETE", base, body: nil)
    _ = try await send("PUT", base, body: #"{"settings":{"number_of_shards":2,"number_of_replicas":0}}"#)
    var next = 1
    while next <= rows {
        let last = min(next + 9_999, rows)
        var body = ""
        for id in next...last {
            body += #"{"index":{"_id":"\#(id)"}}"# + "\n"
            body += #"{"id":\#(id),"payload":"\#(payload(id))"}"# + "\n"
        }
        _ = try await send("POST", "\(base)/_bulk", body: body, contentType: "application/x-ndjson")
        next = last + 1
    }
    _ = try await send("POST", "\(base)/_refresh", body: nil)
}

private func send(_ method: String, _ url: String, body: String?, contentType: String = "application/json") async throws -> Data {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    request.httpBody = body.map { Data($0.utf8) }
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let status = (response as? HTTPURLResponse)?.statusCode, status < 300 else {
        throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
    }
    return data
}
SWIFT
        ;;
    mongodb)
        cat > "$SOURCES/probe_Engine.swift" << 'SWIFT'
import Foundation
import TableProPluginKit

typealias EnginePlugin = MongoDBPlugin
let probeFields: [String: String] = [:]
let probeQuery = "db.tp_stream_probe.find({}).sort({_id: 1})"

func fill(_ driver: any PluginDatabaseDriver, rows: Int, host: String, port: Int) async throws {
    _ = try? await driver.execute(query: "db.tp_stream_probe.drop()")
    var next = 1
    while next <= rows {
        let last = min(next + 4_999, rows)
        let documents = (next...last).map { #"{_id: \#($0), payload: "\#(payload($0))"}"# }.joined(separator: ",")
        _ = try await driver.execute(query: "db.tp_stream_probe.insertMany([\(documents)])")
        next = last + 1
    }
}
SWIFT
        ;;
    trino)
        LIMIT=""
        [ "$ROWS" -lt 1500000 ] && LIMIT=" LIMIT $ROWS"
        cat > "$SOURCES/probe_Engine.swift" << SWIFT
import Foundation
import TableProPluginKit

typealias EnginePlugin = TrinoPlugin
let probeFields: [String: String] = [:]
let probeQuery = "SELECT orderkey, comment, clerk FROM tpch.sf1.orders$LIMIT"

func fill(_ driver: any PluginDatabaseDriver, rows: Int, host: String, port: Int) async throws {}
SWIFT
        ;;
esac

cat > "$SOURCES/probe_Probe.swift" << 'SWIFT'
import Darwin
import Foundation
import TableProPluginKit

func payload(_ id: Int) -> String {
    String(repeating: String(format: "%08lx", (id &* 2_654_435_761) & 0xFFFF_FFFF), count: 12)
}

@main
enum Probe {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 8,
              let port = Int(arguments[2]), let rows = Int(arguments[5]),
              let delay = Int(arguments[6]), let hold = Int(arguments[7]) else {
            print("usage: Probe <host> <port> <user> <password> <rows> <delay us per row> <hold seconds>")
            exit(3)
        }
        let driver = EnginePlugin().createDriver(config: DriverConnectionConfig(
            host: arguments[1], port: port, username: arguments[3], password: arguments[4],
            database: "", additionalFields: probeFields
        ))
        do {
            try await driver.connect()
            try await driver.applyQueryTimeout(0)
            try await fill(driver, rows: rows, host: arguments[1], port: port)
        } catch {
            print("cannot prepare the data: \(error)")
            exit(3)
        }

        let sampler = FootprintSampler()
        let baseline = sampler.start()
        let started = Date()
        var read = 0
        var batches = 0
        var owedMicroseconds = 0
        var failure: Error?
        do {
            for try await element in driver.streamRows(query: probeQuery) {
                guard case .rows(let batch) = element else { continue }
                read += batch.count
                batches += 1
                if batches == 1, hold > 0 {
                    print("holding the stream for \(hold) s after the first batch")
                    try await Task.sleep(for: .seconds(hold))
                }
                // Owed time is slept in 20 ms steps, so a driver that sends one row per element is slowed the same.
                owedMicroseconds += delay * batch.count
                if owedMicroseconds >= 20_000 {
                    try await Task.sleep(for: .microseconds(owedMicroseconds))
                    owedMicroseconds = 0
                }
            }
        } catch {
            failure = error
        }
        let peak = sampler.stop()
        driver.disconnect()

        let megabytes = { (bytes: UInt64) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        print("rows read:          \(read) in \(batches) batches, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
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
"$WORK/.build/release/Probe" "$HOST" "$PORT" "$USER_NAME" "$PASSWORD" "$ROWS" "$DELAY_US" "$HOLD"
