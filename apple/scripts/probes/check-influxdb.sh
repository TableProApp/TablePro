#!/usr/bin/env bash
#
# Check the InfluxDB driver against real 2.x and 3.x servers.
#
# The plugin is registry-only, so no test target compiles it. This builds PluginKit, TableProInfluxDBCore, Plugins/Shared
# and the plugin's own sources with a harness and drives the driver the way the app does: connect, the sidebar catalog,
# the grid's browse, filter and count queries, and typed SQL, InfluxQL and Flux. Both servers must hold the points the
# usage below writes; the probe adds a 2,500-point `load_<time>` measurement to each for the paging checks.
#
# Usage:
#   INFLUX_V2_TOKEN=... INFLUX_V3_TOKEN=... [INFLUX_V2_READ_TOKEN=...] scripts/probes/check-influxdb.sh [v2-url] [v3-url] [v3-auth-url]
#
# Defaults: http://127.0.0.1:28086 (2.x, org with one bucket "metrics"), http://127.0.0.1:28181 (3.x started with
# --without-auth) and http://127.0.0.1:28182 (3.x with auth, INFLUX_V3_TOKEN an admin token). For example
#   docker run -d -p 127.0.0.1:28086:8086 -e DOCKER_INFLUXDB_INIT_MODE=setup -e DOCKER_INFLUXDB_INIT_USERNAME=admin \
#     -e DOCKER_INFLUXDB_INIT_PASSWORD=adminpass123 -e DOCKER_INFLUXDB_INIT_ORG=tp -e DOCKER_INFLUXDB_INIT_BUCKET=metrics \
#     -e DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=$INFLUX_V2_TOKEN influxdb:2
#   docker run -d -p 127.0.0.1:28181:8181 influxdb:3-core influxdb3 serve --node-id a --object-store memory --without-auth
#   docker run -d -p 127.0.0.1:28182:8181 influxdb:3-core influxdb3 serve --node-id b --object-store memory
# and on each, in database or bucket `metrics`:
#   cpu,host=a,region=eu usage=12.5,idle=80i 1730000000
#   cpu,host=b,region=us usage=50.1,idle=40i,note="hot, \"quoted\"" 1730000060
#   cpu,host=c,region=eu,zone=1 usage=7.0,idle=10i,note="a;b" 1730000120
#   mem,host=a used=1024i 1730000000
# On 2.x also a bucket `renamed` holding `evt,k=x v=1i 1730000000`, mapped for InfluxQL as database `legacy_db`:
#   influx bucket create -n renamed -o tp; influx v1 dbrp create --db legacy_db --rp autogen --bucket-id <id> --default
# and a bucket `telegraf/weekly` holding `disk,host=a used=1i 1730000000`, which InfluxQL reads as db telegraf, rp weekly.
# Exits 0 when every check passes, 1 when one fails, and 3 when the check could not run.

set -uo pipefail

V2_URL="${1:-http://127.0.0.1:28086}"
V3_URL="${2:-http://127.0.0.1:28181}"
V3_AUTH_URL="${3:-http://127.0.0.1:28182}"
: "${INFLUX_V2_TOKEN:?set INFLUX_V2_TOKEN}"
: "${INFLUX_V3_TOKEN:?set INFLUX_V3_TOKEN}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="$ROOT/Plugins/InfluxDBDriverPlugin"
KIT="$ROOT/Plugins/TableProPluginKit"
CORE="$ROOT/Packages/TableProCore/Sources/TableProInfluxDBCore"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import TableProInfluxDBCore
import TableProPluginKit

final class Tally: @unchecked Sendable {
    var failures = 0

    func check(_ passed: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        print(passed ? "ok   \(what)" : "FAIL \(what) \(detail())")
        if !passed { failures += 1 }
    }
}

func driver(_ url: String, token: String, database: String = "metrics") -> InfluxDBPluginDriver {
    let components = URLComponents(string: url)!
    return InfluxDBPluginDriver(config: DriverConnectionConfig(
        host: components.host ?? "127.0.0.1", port: components.port ?? 8086,
        username: "", password: "", database: database,
        additionalFields: [InfluxDBFieldID.token: token]
    ))
}

func texts(_ result: PluginQueryResult, _ column: String) -> [String?] {
    guard let index = result.columns.firstIndex(of: column) else { return [] }
    return result.rows.map { $0[index].asText }
}

func write(_ url: String, path: String, token: String, lines: String) async throws {
    var request = URLRequest(url: URL(string: url + path)!)
    request.httpMethod = "POST"
    request.httpBody = Data(lines.utf8)
    if !token.isEmpty { request.setValue("Token \(token)", forHTTPHeaderField: "Authorization") }
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
        throw InfluxError.query("write failed: \(response)")
    }
}

// A fresh name per run: 3.x keeps a point written twice before it persists as two rows.
let load = "load_\(Int(Date().timeIntervalSince1970))"

func loadLines() -> String {
    (0 ..< 2_500).map { "\(load),shard=s\($0 % 3) n=\($0)i \(1_700_000_000 + $0)" }.joined(separator: "\n")
}

func grid(_ driver: InfluxDBPluginDriver, _ table: String, filters: [PluginQueryFilter] = [],
          sort: [(columnIndex: Int, ascending: Bool)] = [], columns: [String] = [],
          limit: Int = 100, offset: Int = 0) async throws -> PluginQueryResult {
    guard let query = driver.buildFilteredQuery(
        table: table, schema: nil, queryFilters: filters, logicMode: "and", sortColumns: sort,
        columns: columns, limit: limit, offset: offset, columnKinds: [:]
    ) else { throw InfluxError.query("filter refused") }
    return try await driver.execute(query: query)
}

func shared(_ tally: Tally, _ driver: InfluxDBPluginDriver, label: String, url: String, token: String) async throws {
    let isV2 = label.hasPrefix("2.")
    let databases = try await driver.fetchDatabases()
    tally.check(databases.contains("metrics"), "\(label): databases list metrics", "\(databases)")

    let cold = InfluxDBPluginDriver(config: DriverConnectionConfig(
        host: URLComponents(string: url)!.host!, port: URLComponents(string: url)!.port!,
        username: "", password: "", database: "metrics", additionalFields: [InfluxDBFieldID.token: token]
    ))
    try await cold.connect()
    let coldZone = try await grid(cold, "cpu", filters: [PluginQueryFilter(column: "zone", op: "=", value: "1")])
    tally.check(texts(coldZone, "host") == ["c"], "\(label): numeric tag value filtered before any column fetch",
                "\(texts(coldZone, "host"))")
    tally.check(coldZone.columnTypeNames[coldZone.columns.firstIndex(of: "zone")!] == "tag",
                "\(label): grid result typed from the schema", "\(coldZone.columnTypeNames)")
    cold.disconnect()

    let tables = try await driver.fetchTables(schema: nil)
    tally.check(tables.contains { $0.name == "cpu" } && tables.allSatisfy { $0.type == "EXTERNAL TABLE" },
                "\(label): measurements are external tables", "\(tables.map { "\($0.name):\($0.type)" })")
    let columns = try await driver.fetchColumns(table: "cpu", schema: nil)
    tally.check(columns.map(\.name) == ["time", "host", "idle", "note", "region", "usage", "zone"],
                "\(label): columns time first", "\(columns.map(\.name))")
    tally.check(columns.map(\.dataType) == ["timestamp", "tag", "integer", "string", "tag", "float", "tag"],
                "\(label): column types", "\(columns.map(\.dataType))")
    tally.check(!columns.contains { $0.isPrimaryKey }, "\(label): no column claims to be a key")

    let browse = try await driver.execute(query: driver.buildBrowseQuery(
        table: "cpu", sortColumns: [], columns: columns.map(\.name), limit: 100, offset: 0
    )!)
    tally.check(browse.rows.count == 3, "\(label): browse returns every point", "\(browse.rows.count)")
    tally.check(texts(browse, "time").first == "2024-10-27T03:35:20Z", "\(label): newest first, RFC 3339 time",
                "\(texts(browse, "time"))")
    tally.check(texts(browse, "note").contains("hot, \"quoted\""), "\(label): quoted string field round-trips",
                "\(texts(browse, "note"))")
    tally.check(texts(browse, "note").contains(nil), "\(label): missing field reads as null")

    let byHost = try await grid(driver, "cpu", filters: [PluginQueryFilter(column: "host", op: "=", value: "a")])
    tally.check(texts(byHost, "host") == ["a"], "\(label): tag equality filter", "\(texts(byHost, "host"))")
    let fresh = "fresh_\(Int(Date().timeIntervalSince1970))"
    let writePath = isV2 ? "/api/v2/write?org=tp&bucket=metrics&precision=s" : "/api/v3/write_lp?db=metrics&precision=second"
    try await write(url, path: writePath, token: token, lines: "\(fresh),host=a v=1i 1730000000")
    _ = try await grid(driver, fresh)
    try await write(url, path: writePath, token: token, lines: "\(fresh),host=b,rack=7 v=2i 1730000060")
    let gained = try await grid(driver, fresh, filters: [PluginQueryFilter(column: "rack", op: "=", value: "7")])
    tally.check(texts(gained, "host") == ["b"], "\(label): a tag added after the schema was read filters as text",
                "\(texts(gained, "host"))")
    let semicolon = try await grid(driver, "cpu", filters: [PluginQueryFilter(column: "note", op: "=", value: "a;b")])
    tally.check(texts(semicolon, "host") == ["c"], "\(label): a value holding ; filters", "\(texts(semicolon, "host"))")
    let numeric = try await grid(driver, "cpu", filters: [PluginQueryFilter(column: "usage", op: ">", value: "20")])
    tally.check(texts(numeric, "host") == ["b"], "\(label): numeric field filter", "\(texts(numeric, "host"))")
    let contains = try await grid(driver, "cpu", filters: [
        PluginQueryFilter(column: "note", op: "CONTAINS", value: "HOT, \"", isCaseSensitive: false),
    ])
    tally.check(contains.rows.count == 1, "\(label): case-insensitive contains", "\(contains.rows.count)")
    let inList = try await grid(driver, "cpu", filters: [PluginQueryFilter(column: "region", op: "IN", value: "eu, us")])
    tally.check(inList.rows.count == 3, "\(label): IN list", "\(inList.rows.count)")
    let noZone = try await grid(driver, "cpu", filters: [PluginQueryFilter(column: "zone", op: "IS NULL", value: "")])
    tally.check(Set(texts(noZone, "host").compactMap { $0 }) == ["a", "b"], "\(label): IS NULL on a tag",
                "\(texts(noZone, "host"))")
    let fieldNull = driver.buildFilteredQuery(
        table: "cpu", schema: nil, queryFilters: [PluginQueryFilter(column: "note", op: "IS NULL", value: "")],
        logicMode: "and", sortColumns: [], columns: [], limit: 100, offset: 0, columnKinds: [:]
    )
    if isV2 {
        tally.check(fieldNull == nil, "\(label): IS NULL on a field is refused, InfluxQL has no such test")
    } else {
        let rows = try await driver.execute(query: fieldNull ?? "")
        tally.check(texts(rows, "host") == ["a"], "\(label): IS NULL on a field", "\(texts(rows, "host"))")
    }
    let nothing = try await grid(driver, "cpu", filters: [PluginQueryFilter(column: "host", op: "=", value: "none")])
    tally.check(nothing.rows.isEmpty && nothing.columns.contains("host"), "\(label): an empty page keeps its columns",
                "\(nothing.columns)")
    let ascending = try await grid(driver, "cpu", sort: [(columnIndex: 0, ascending: true)], columns: ["time", "host"])
    tally.check(texts(ascending, "host") == ["a", "b", "c"], "\(label): sort by time ascending",
                "\(texts(ascending, "host"))")

    let page = try await grid(driver, load, limit: 1_000, offset: 2_000)
    tally.check(page.rows.count == 500, "\(label): third page of 2,500 holds 500", "\(page.rows.count)")
    let count = try await driver.fetchExactRowCount(table: load, schema: nil, queryFilters: [], logicMode: "and")
    tally.check(count == 2_500, "\(label): exact count", "\(String(describing: count))")
    let filteredCount = try await driver.fetchExactRowCount(
        table: load, schema: nil, queryFilters: [PluginQueryFilter(column: "shard", op: "=", value: "s0")],
        logicMode: "and"
    )
    tally.check(filteredCount == 834, "\(label): filtered count", "\(String(describing: filteredCount))")
    let sparse = try await driver.fetchExactRowCount(table: "cpu", schema: nil, queryFilters: [], logicMode: "and")
    tally.check(sparse == (isV2 ? nil : 3), "\(label): a sparse measurement counts points or reports none",
                "\(String(describing: sparse))")

    let show = try await driver.execute(query: "SHOW TAG KEYS FROM \"cpu\"")
    tally.check(texts(show, "tagKey") == ["host", "region", "zone"], "\(label): SHOW TAG KEYS runs as InfluxQL",
                "\(show.columns) \(show.rows)")
    let marked = try await driver.execute(query: "// influxql\nSHOW MEASUREMENTS")
    tally.check(!marked.rows.isEmpty, "\(label): a // influxql marker is not sent", "\(marked.rows.count)")
    await expectFailure(tally, "\(label): typed InfluxQL holding a ; is refused", contains: "one InfluxQL statement") {
        _ = try await driver.execute(query: "-- influxql\nSELECT /'/ FROM cpu; DROP MEASUREMENT \(fresh) -- '")
    }
    let scratch = "scratch_\(Int(Date().timeIntervalSince1970))"
    try await write(url, path: writePath, token: token, lines: "\(scratch),host=a v=1i 1730000000")
    let exploit = "\u{0600}/ GROUP BY /\u{0301}'\u{0600}/; DROP MEASUREMENT \(scratch) --'"
    _ = try? await grid(driver, "cpu", filters: [PluginQueryFilter(column: "host", op: "CONTAINS", value: exploit)])
    let survivors = try await driver.fetchTables(schema: nil).map(\.name)
    tally.check(survivors.contains(scratch), "\(label): a filter value cannot end the regex and run a DROP",
                "\(survivors)")
    try await driver.ping()
    tally.check(true, "\(label): health ping")

    do {
        _ = try driver.generateRowWrites(
            table: "cpu", schema: nil, columns: ["time"], primaryKeyColumns: [],
            changes: [PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: nil)],
            insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        tally.check(false, "\(label): a row delete is refused", "no refusal")
    } catch {
        tally.check(error is PluginRowWriteRefusal, "\(label): a row delete is refused", "\(error)")
    }
}

func expectFailure(_ tally: Tally, _ what: String, contains needle: String,
                   _ body: @Sendable () async throws -> Void) async {
    do {
        try await body()
        tally.check(false, what, "no error")
    } catch {
        let message = error.localizedDescription
        tally.check(message.localizedCaseInsensitiveContains(needle), what, message)
    }
}

@main
struct Probe {
    static func main() async {
        let arguments = CommandLine.arguments
        let (v2URL, v3URL, v3AuthURL) = (arguments[1], arguments[2], arguments[3])
        let v2Token = ProcessInfo.processInfo.environment["INFLUX_V2_TOKEN"] ?? ""
        let v3Token = ProcessInfo.processInfo.environment["INFLUX_V3_TOKEN"] ?? ""
        let tally = Tally()
        do {
            try await write(v2URL, path: "/api/v2/write?org=tp&bucket=metrics&precision=s", token: v2Token,
                            lines: loadLines())
            try await write(v3URL, path: "/api/v3/write_lp?db=metrics&precision=second", token: "", lines: loadLines())
            try await write(v3AuthURL, path: "/api/v3/write_lp?db=metrics&precision=second", token: v3Token,
                            lines: loadLines())

            let v3 = driver(v3URL, token: "")
            try await v3.connect()
            tally.check(v3.serverVersion?.hasPrefix("3.") == true, "3.x: version", v3.serverVersion ?? "nil")
            try await shared(tally, v3, label: "3.x", url: v3URL, token: "")
            let averages = try await v3.execute(query: """
            SELECT date_bin(INTERVAL '1 minute', time) AS bucket, avg(usage) AS mean FROM cpu GROUP BY bucket ORDER BY bucket
            """)
            tally.check(averages.columns == ["bucket", "mean"] && averages.rows.count == 3, "3.x: SQL aggregate",
                        "\(averages.columns) \(averages.rows.count)")
            let influxQL = try await v3.execute(query: "SELECT MEAN(usage) FROM cpu WHERE time > now() - 10000d GROUP BY time(1h)")
            tally.check(influxQL.columns.contains("mean"), "3.x: InfluxQL GROUP BY time() routes to InfluxQL",
                        "\(influxQL.columns)")
            let sqlMarker = try await v3.execute(query: "// sql\nSELECT 1 AS one")
            tally.check(texts(sqlMarker, "one") == ["1"], "3.x: a // sql marker is not sent", "\(sqlMarker.rows)")
            await expectFailure(tally, "3.x: Flux refused with the languages it takes", contains: "SQL, InfluxQL") {
                _ = try await v3.execute(query: "from(bucket: \"metrics\") |> range(start: -1h)")
            }
            await expectFailure(tally, "3.x: SQL error text reaches the user", contains: "SELEC") {
                _ = try await v3.execute(query: "SELEC nope")
            }
            try await v3.switchDatabase(to: "")
            let allDatabases = try await v3.execute(query: "SHOW DATABASES")
            tally.check(texts(allDatabases, "iox::database").contains("metrics"),
                        "3.x: SHOW DATABASES runs with no database chosen", "\(allDatabases.columns)")
            await expectFailure(tally, "3.x: SQL with no database asks for one", contains: "database") {
                _ = try await v3.execute(query: "SELECT 1")
            }
            v3.disconnect()

            await expectFailure(tally, "3.x auth: a wrong token fails the connect", contains: "token") {
                try await driver(v3AuthURL, token: "wrong").connect()
            }
            let v3Auth = driver(v3AuthURL, token: v3Token)
            try await v3Auth.connect()
            try await shared(tally, v3Auth, label: "3.x auth", url: v3AuthURL, token: v3Token)
            v3Auth.disconnect()

            await expectFailure(tally, "2.x: a wrong token fails the connect", contains: "token") {
                try await driver(v2URL, token: "wrong").connect()
            }
            let v2 = driver(v2URL, token: v2Token)
            try await v2.connect()
            tally.check(v2.serverVersion?.hasPrefix("v2.") == true, "2.x: version", v2.serverVersion ?? "nil")
            try await shared(tally, v2, label: "2.x", url: v2URL, token: v2Token)
            let databases = try await v2.fetchDatabases()
            tally.check(databases.contains("_monitoring"), "2.x: system buckets listed", "\(databases)")
            let flux = try await v2.execute(query: """
            -- flux
            from(bucket: "metrics")
              |> range(start: 0)
              |> filter(fn: (r) => r._measurement == "cpu")
              |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
            """)
            tally.check(flux.rows.count == 3 && flux.columns.contains("usage") && !flux.columns.contains("result"),
                        "2.x: a -- flux marker is not sent, pivot reads as one grid",
                        "\(flux.columns) \(flux.rows.count)")
            tally.check(flux.columnTypeNames[flux.columns.firstIndex(of: "_time")!] == "timestamp",
                        "2.x: Flux time typed", "\(flux.columnTypeNames)")
            await expectFailure(tally, "2.x: Flux error text reaches the user", contains: "undefined identifier") {
                _ = try await v2.execute(query: "from(bucket: \"metrics\") |> nope()")
            }
            await expectFailure(tally, "2.x: a Flux write the lexer misreads is refused by the server's parse",
                                contains: "reads this Flux script") {
                _ = try await v2.execute(query: """
                import "array"
                /"/
                array.from(rows: [{a: 1}]) |> to(bucket: "tp_probe_nonexistent")
                // "
                """)
            }
            if let readToken = ProcessInfo.processInfo.environment["INFLUX_V2_READ_TOKEN"], !readToken.isEmpty {
                let reader = InfluxDBPluginDriver(config: DriverConnectionConfig(
                    host: URLComponents(string: v2URL)?.host ?? "127.0.0.1", port: URLComponents(string: v2URL)?.port ?? 8086,
                    username: "", password: "", database: "telegraf/weekly",
                    additionalFields: [InfluxDBFieldID.token: readToken, InfluxDBFieldID.organization: "tp"]
                ))
                try await reader.connect()
                let fluxRead = try await reader.execute(query: "from(bucket: \"telegraf/weekly\") |> range(start: 0)")
                tally.check(!fluxRead.rows.isEmpty, "2.x: a read-only token runs Flux past the server parse",
                            "\(fluxRead.rows.count)")
                reader.disconnect()
            }
            await expectFailure(tally, "2.x: SQL refused", contains: "Flux, InfluxQL") {
                _ = try await v2.execute(query: "-- sql\nSELECT 1 FROM cpu")
            }
            let grouped = try await v2.execute(query: "SELECT MEAN(usage) FROM cpu GROUP BY host")
            tally.check(grouped.columns == ["host", "time", "mean"] && grouped.rows.count == 3,
                        "2.x: GROUP BY tag series flatten", "\(grouped.columns) \(grouped.rows)")
            try await v2.switchDatabase(to: "renamed")
            let renamed = try await v2.fetchTables(schema: nil).map(\.name)
            tally.check(renamed == ["evt"], "2.x: a bucket with its own DBRP mapping lists its measurements", "\(renamed)")
            try await v2.switchDatabase(to: "telegraf/weekly")
            let slashed = try await v2.fetchTables(schema: nil).map(\.name)
            tally.check(slashed == ["disk"], "2.x: a db/rp bucket reads through its mapping", "\(slashed)")
            let disk = try await grid(v2, "disk")
            tally.check(disk.rows.count == 1, "2.x: a db/rp bucket's grid", "\(disk.rows.count)")
            v2.disconnect()
        } catch {
            tally.check(false, "probe ran to the end", "\(error)")
        }
        print(tally.failures == 0 ? "PASS" : "FAIL (\(tally.failures))")
        exit(tally.failures == 0 ? 0 : 1)
    }
}
SWIFT

KIT_SOURCES=()
while IFS= read -r file; do KIT_SOURCES+=("$file"); done < <(find "$KIT" -name '*.swift')
CORE_SOURCES=()
while IFS= read -r file; do CORE_SOURCES+=("$file"); done < <(find "$CORE" -name '*.swift')
PLUGIN_SOURCES=()
while IFS= read -r file; do PLUGIN_SOURCES+=("$file"); done < <(find "$PLUGIN" "$ROOT/Plugins/Shared" -name '*.swift')

mkdir -p "$WORK/modules"
echo "building PluginKit, TableProInfluxDBCore and the InfluxDB plugin..."
xcrun swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name TableProPluginKit \
    -emit-module-path "$WORK/modules/TableProPluginKit.swiftmodule" \
    -o "$WORK/libTableProPluginKit.dylib" \
    "${KIT_SOURCES[@]}" > "$WORK/build.log" 2>&1 &&
    xcrun swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name TableProInfluxDBCore \
        -emit-module-path "$WORK/modules/TableProInfluxDBCore.swiftmodule" \
        -o "$WORK/libTableProInfluxDBCore.dylib" \
        "${CORE_SOURCES[@]}" >> "$WORK/build.log" 2>&1 &&
    xcrun swiftc -swift-version 6 -parse-as-library -module-name InfluxDBProbe \
        -I "$WORK/modules" -L "$WORK" -lTableProPluginKit -lTableProInfluxDBCore \
        -Xlinker -rpath -Xlinker "$WORK" \
        "${PLUGIN_SOURCES[@]}" "$WORK/main.swift" -o "$WORK/probe" \
        >> "$WORK/build.log" 2>&1 || {
    cat "$WORK/build.log" >&2
    exit 3
}

"$WORK/probe" "$V2_URL" "$V3_URL" "$V3_AUTH_URL"
