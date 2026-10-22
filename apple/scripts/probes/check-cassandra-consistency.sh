#!/usr/bin/env bash
#
# Check that the Cassandra driver runs each statement at the consistency level it reports, against a real server.
#
# The plugin is registry-only, so no test target compiles it. This builds PluginKit, Plugins/Shared and the plugin's
# own sources with a harness, links the shipped Libs/libcassandra.a, and drives the driver the way the app does. One
# node cannot meet TWO, so a read that succeeds at ONE and fails at TWO proves the level reached the wire rather than
# only the footer. On one node the server's "Cannot achieve consistency level TWO" arrives as the driver's "All hosts
# in current policy attempted", because its retry policy tries a next host first. It also checks that the plugin's own catalog reads and the health check keep the driver's
# default while the session runs at a level that refuses them, and that a CONSISTENCY line never reaches the server.
#
# Usage:
#   scripts/probes/check-cassandra-consistency.sh [host] [port]
#
# Needs a single-node Cassandra 4 or 5 or ScyllaDB, for example
#   docker run -d --name cassandra-probe -p 127.0.0.1:9042:9042 cassandra:5.0
# Creates the keyspace tp_consistency_probe and drops it at the end. Exits 0 when every check passes, 1 when one
# fails, and 3 when the check could not run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-9042}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="$ROOT/Plugins/CassandraDriverPlugin"
KIT="$ROOT/Plugins/TableProPluginKit"
LIBS="$ROOT/Libs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for library in libcassandra.a libuv.a dylibs/libssl.3.dylib dylibs/libcrypto.3.dylib; do
    [ -f "$LIBS/$library" ] || {
        echo "not found: Libs/$library (run scripts/download-libs.sh)" >&2
        exit 3
    }
done

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import TableProPluginKit

final class Tally: @unchecked Sendable {
    var failures = 0

    func check(_ passed: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        print(passed ? "ok   \(what)" : "FAIL \(what) \(detail())")
        if !passed { failures += 1 }
    }
}

func message(of error: Error) -> String {
    (error as? PluginDriverError)?.pluginErrorMessage ?? error.localizedDescription
}

func driver(_ host: String, _ port: Int, _ fields: [String: String] = [:]) -> CassandraPluginDriver {
    CassandraPluginDriver(config: DriverConnectionConfig(
        host: host, port: port, username: "", password: "", database: "", additionalFields: fields
    ))
}

@main
enum Probe {
    static func main() async {
        let host = CommandLine.arguments[1]
        let port = Int(CommandLine.arguments[2]) ?? 9_042
        let tally = Tally()
        let table = "tp_consistency_probe.t"

        let session = driver(host, port)
        do {
            try await session.connect()
        } catch {
            print("cannot connect: \(message(of: error))")
            exit(3)
        }

        func status(_ statement: String) async -> String? {
            do {
                return try await session.execute(query: statement).statusMessage
            } catch {
                return "error: \(message(of: error))"
            }
        }

        _ = await status("DROP KEYSPACE IF EXISTS tp_consistency_probe")
        _ = await status("""
            CREATE KEYSPACE tp_consistency_probe
            WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}
            """)
        _ = await status("CREATE TABLE \(table) (id int PRIMARY KEY, v text)")
        _ = await status("INSERT INTO \(table) (id, v) VALUES (1, 'a')")

        tally.check(await status("SELECT * FROM \(table)") == "Consistency: LOCAL_ONE", "an unset connection reads at LOCAL_ONE")
        tally.check(await status("CONSISTENCY") == "Current consistency level is LOCAL_ONE.", "CONSISTENCY alone names the level")

        let setTwo = await status("CONSISTENCY TWO;")
        tally.check(setTwo == "Consistency level set to TWO.", "CONSISTENCY TWO; answers as cqlsh does", setTwo ?? "nil")
        let readAtTwo = await status("SELECT * FROM \(table)")
        tally.check(readAtTwo?.hasPrefix("error") == true, "a read after CONSISTENCY TWO is sent at TWO",
                    readAtTwo ?? "nil")

        do {
            let tables = try await session.fetchTables(schema: "tp_consistency_probe")
            tally.check(tables.map(\.name) == ["t"], "the catalog reads at the driver default under TWO")
            try await session.ping()
            tally.check(true, "the health check reads at the driver default under TWO")
        } catch {
            tally.check(false, "the catalog and health check under TWO", message(of: error))
        }

        do {
            _ = try await session.executeParameterized(
                query: "INSERT INTO \(table) (id, v) VALUES (?, ?)", parameters: [.text("2"), .text("b")]
            )
            tally.check(false, "a prepared write after CONSISTENCY TWO is sent at TWO")
        } catch {
            tally.check(true, "a prepared write after CONSISTENCY TWO is sent at TWO")
        }

        let lowered = await status("-- relax it\nconsistency one -- trailing note")
        tally.check(lowered == "Consistency level set to ONE.", "comments and lower case are accepted", lowered ?? "nil")
        tally.check(await status("SELECT * FROM \(table)") == "Consistency: ONE", "the next read runs at ONE")

        let glued = await status("CONSISTENCY QUORUM\nSELECT * FROM \(table)")
        tally.check(glued?.contains("takes one level") == true, "a command run into a statement is refused", glued ?? "nil")
        tally.check(await status("CONSISTENCY") == "Current consistency level is ONE.", "a refused command changes nothing")
        let unknown = await status("CONSISTENCY FOO")
        tally.check(unknown?.contains("is not a level") == true, "an unknown level is refused", unknown ?? "nil")
        let wrongSerial = await status("SERIAL CONSISTENCY QUORUM")
        tally.check(wrongSerial?.contains("SERIAL, LOCAL_SERIAL") == true, "SERIAL CONSISTENCY takes only serial levels",
                    wrongSerial ?? "nil")

        tally.check(await status("SERIAL CONSISTENCY") == "Current serial consistency level is SERIAL.",
                    "SERIAL CONSISTENCY alone names the server default")
        tally.check(await status("SERIAL CONSISTENCY LOCAL_SERIAL") == "Serial consistency level set to LOCAL_SERIAL.",
                    "SERIAL CONSISTENCY LOCAL_SERIAL is accepted")
        let conditional = await status("INSERT INTO \(table) (id, v) VALUES (3, 'c') IF NOT EXISTS")
        tally.check(conditional == "Consistency: ONE, serial: LOCAL_SERIAL", "a conditional write names both levels",
                    conditional ?? "nil")

        do {
            let bounded = try await session.executeBoundedQuery(query: "SELECT * FROM \(table)", rowCap: 10)
            tally.check(bounded?.statusMessage == "Consistency: ONE", "a capped read names its level",
                        bounded?.statusMessage ?? "nil")
            let browseText = session.buildBrowseQuery(
                table: "t", schema: "tp_consistency_probe", sortColumns: [], columns: ["id", "v"], limit: 10, offset: 0
            )
            if let browseText {
                let browse = try await session.execute(query: browseText)
                tally.check(browse.statusMessage == "Consistency: ONE" && !browse.rows.isEmpty,
                            "a table browse names its level", browse.statusMessage ?? "nil")
            } else {
                tally.check(false, "a table browse statement is built")
            }
        } catch {
            tally.check(false, "capped read and browse", message(of: error))
        }

        tally.check(await status("CONSISTENCY ANY") == "Consistency level set to ANY.", "CONSISTENCY ANY is accepted")
        let anyRead = await status("SELECT * FROM \(table)")
        tally.check(anyRead?.hasPrefix("error") == true, "a read at ANY is refused by the server", anyRead ?? "nil")
        tally.check(await status("INSERT INTO \(table) (id, v) VALUES (4, 'd')") == "Consistency: ANY",
                    "a write at ANY runs")
        do {
            let tables = try await session.fetchTables(schema: "tp_consistency_probe")
            tally.check(tables.count == 1, "the catalog still reads under ANY")
        } catch {
            tally.check(false, "the catalog still reads under ANY", message(of: error))
        }

        var streamedHeader = false
        do {
            for try await element in session.streamRows(query: "CONSISTENCY QUORUM") {
                if case .header = element { streamedHeader = true }
            }
        } catch {
            tally.check(false, "a streamed CONSISTENCY line", message(of: error))
        }
        tally.check(streamedHeader && session.sessionConsistency?.level == .quorum,
                    "a streamed CONSISTENCY line sets the level without the server")

        session.disconnect()
        try? await Task.sleep(nanoseconds: 300_000_000)
        do {
            try await session.connect()
            tally.check(await status("SELECT * FROM \(table)") == "Consistency: LOCAL_ONE",
                        "a reconnect returns to the connection's level")
        } catch {
            tally.check(false, "reconnect", message(of: error))
        }

        let configured = driver(host, port, ["cassandraConsistency": "TWO", "cassandraSerialConsistency": "LOCAL_SERIAL"])
        do {
            try await configured.connect()
            let read = try? await configured.execute(query: "SELECT * FROM \(table)")
            tally.check(read == nil, "a connection set to TWO reads at TWO")
            let level = try? await configured.execute(query: "SERIAL CONSISTENCY").statusMessage
            tally.check(level == "Current serial consistency level is LOCAL_SERIAL.", "the connection's serial level is used")
            configured.disconnect()
        } catch {
            tally.check(false, "a connection set to TWO connects", message(of: error))
        }

        do {
            try await driver(host, port, ["cassandraConsistency": "SERIAL"]).connect()
            tally.check(false, "a connection level of SERIAL is refused")
        } catch {
            tally.check(message(of: error).contains("SERIAL"), "a connection level of SERIAL is refused", message(of: error))
        }

        let keyspacesHosts = [
            "cassandra.us-east-1.amazonaws.com", "cassandra-fips.us-gov-west-1.amazonaws.com",
            "cassandra.cn-north-1.amazonaws.com.cn", "cassandra.eu-west-1.api.aws",
            "vpce-0a1b2c3d-4e5f.cassandra.us-east-1.vpce.amazonaws.com", "CASSANDRA.US-EAST-1.AMAZONAWS.COM.",
        ]
        for name in keyspacesHosts {
            let resolved = try? CassandraConsistency(additionalFields: [:], host: name)
            tally.check(resolved?.level == .localQuorum, "\(name) defaults to LOCAL_QUORUM")
        }
        for name in ["localhost", "127.0.0.1", "cassandra.internal.example.com", "mycassandra.us-east-1.amazonaws.com"] {
            let resolved = try? CassandraConsistency(additionalFields: [:], host: name)
            tally.check(resolved?.level == .localOne, "\(name) defaults to LOCAL_ONE")
        }
        let tunneled = try? CassandraConsistency(
            additionalFields: ["preTunnelHost": "cassandra.us-east-1.amazonaws.com"], host: "127.0.0.1"
        )
        tally.check(tunneled?.level == .localQuorum, "a Keyspaces endpoint behind an SSH tunnel defaults to LOCAL_QUORUM")
        let iam = try? CassandraConsistency(additionalFields: ["awsAuth": "profile"], host: "127.0.0.1")
        tally.check(iam?.level == .localQuorum, "AWS IAM authentication defaults to LOCAL_QUORUM")
        let chosen = try? CassandraConsistency(
            additionalFields: ["cassandraConsistency": "local_one"], host: "cassandra.us-east-1.amazonaws.com"
        )
        tally.check(chosen?.level == .localOne, "a chosen level wins over the Keyspaces default")

        _ = await status("DROP KEYSPACE IF EXISTS tp_consistency_probe")
        session.disconnect()
        print(tally.failures == 0 ? "PASS" : "FAIL: \(tally.failures) check(s)")
        exit(tally.failures == 0 ? 0 : 1)
    }
}
SWIFT

KIT_SOURCES=()
while IFS= read -r file; do KIT_SOURCES+=("$file"); done < <(find "$KIT" -name '*.swift')
PLUGIN_SOURCES=()
while IFS= read -r file; do PLUGIN_SOURCES+=("$file"); done < <(find "$PLUGIN" "$ROOT/Plugins/Shared" -name '*.swift')

mkdir -p "$WORK/modules"
echo "building PluginKit and the Cassandra plugin..."
xcrun swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name TableProPluginKit \
    -emit-module-path "$WORK/modules/TableProPluginKit.swiftmodule" \
    -o "$WORK/libTableProPluginKit.dylib" \
    "${KIT_SOURCES[@]}" > "$WORK/build.log" 2>&1 &&
    xcrun swiftc -swift-version 6 -parse-as-library -module-name CassandraConsistencyProbe \
        -I "$WORK/modules" -L "$WORK" -lTableProPluginKit \
        -I "$PLUGIN/CCassandra" -Xcc "-I$PLUGIN/CCassandra/include" \
        -L "$LIBS/dylibs" \
        -Xlinker -force_load -Xlinker "$LIBS/libcassandra.a" -Xlinker -force_load -Xlinker "$LIBS/libuv.a" \
        -lssl.3 -lcrypto.3 -lc++ -lz \
        -Xlinker -rpath -Xlinker "$WORK" -Xlinker -rpath -Xlinker "$LIBS/dylibs" \
        "${PLUGIN_SOURCES[@]}" "$WORK/main.swift" -o "$WORK/probe" \
        >> "$WORK/build.log" 2>&1 || {
    cat "$WORK/build.log" >&2
    exit 3
}

"$WORK/probe" "$HOST" "$PORT"
