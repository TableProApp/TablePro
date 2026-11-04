import Darwin
import Foundation
import TableProPluginKit

let environment = ProcessInfo.processInfo.environment
var failures = 0
var ssl = SSLConfiguration()
ssl.mode = SSLMode(rawValue: environment["HYDRADB_PROBE_SSL_MODE"] ?? "") ?? .disabled
ssl.caCertificatePath = environment["HYDRADB_PROBE_CA"] ?? ""
let driver = HydraDBPluginDriver(config: DriverConnectionConfig(
    host: "127.0.0.1",
    port: 17_687,
    username: "tablepro-probe",
    password: environment["HYDRADB_PROBE_TOKEN"] ?? "",
    database: "default",
    ssl: ssl
))

@MainActor
func record(_ name: String, operation: () async throws -> Any) async {
    let started = Date()
    var result: [String: Any] = ["name": name]
    do {
        result["value"] = try await operation()
        result["status"] = "accepted"
    } catch {
        failures += 1
        result["status"] = "rejected"
        result["message"] = error.localizedDescription
    }
    result["elapsed_ms"] = Date().timeIntervalSince(started) * 1_000
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
        preconditionFailure("Probe output is not UTF-8")
    }
    print(text)
}

try await driver.connect()
if environment["HYDRADB_PROBE_CONNECTION_ONLY"] == "1" {
    try await driver.ping()
    print("HydraDB connection and health check passed")
    driver.disconnect()
    exit(0)
}
await record("tablepro-ping") {
    try await driver.ping()
    return true
}
await record("tablepro-tables") {
    try await (driver.fetchTablesInAllSchemas() ?? []).map {
        ["name": $0.name, "schema": $0.schema ?? ""]
    }
}
await record("tablepro-scalar-query") {
    let result = try await driver.execute(query:
        "MATCH (n:TableProProbe) RETURN n.id AS id, n.name AS name ORDER BY n.id"
    )
    return [
        "columns": result.columns,
        "rows": result.rows.map { row in row.map { $0.asText as Any? ?? NSNull() } }
    ] as [String: Any]
}
await record("tablepro-columns") {
    try await driver.fetchColumns(table: "TableProProbe", schema: "Labels").map(\.name)
}
await record("tablepro-row-count") {
    let count = try await driver.fetchApproximateRowCount(table: "TableProProbe", schema: "Labels")
    guard count == 2 else { throw NSError(domain: "Probe.Count", code: 1) }
    return count as Any
}
await record("tablepro-node-browser") {
    guard let query = driver.buildBrowseQuery(
        table: "TableProProbe", schema: "Labels", sortColumns: [], columns: [], limit: 100, offset: 0
    ) else { throw NSError(domain: "Probe", code: 1) }
    let result = try await driver.execute(query: query)
    return result.rows.count
}
await record("tablepro-relationship-browser") {
    guard let query = driver.buildBrowseQuery(
        table: "TABLEPRO_KNOWS", schema: "Relationship Types", sortColumns: [], columns: [], limit: 100, offset: 0
    ) else { throw NSError(domain: "Probe", code: 1) }
    let result = try await driver.execute(query: query)
    guard !result.rows.isEmpty, result.columns.contains("<start>"), result.columns.contains("<end>"),
          let identityIndex = result.columns.firstIndex(of: "<id>"),
          Set(result.rows.compactMap { $0[identityIndex].asText }).count == result.rows.count else {
        throw NSError(domain: "Probe.Relationship", code: 1)
    }
    return ["columns": result.columns, "rows": result.rows.map { $0.map { $0.asText as Any? ?? NSNull() } }] as [String: Any]
}
await record("tablepro-property-filter") {
    guard let query = driver.buildFilteredQuery(
        table: "TableProProbe", schema: "Labels",
        queryFilters: [PluginQueryFilter(column: "name", op: "=", value: "Ann", isCaseSensitive: true)],
        logicMode: "and", sortColumns: [], columns: [], limit: 100, offset: 0, columnKinds: ["name": .text]
    ) else { throw NSError(domain: "Probe.Filter", code: 1) }
    let result = try await driver.execute(query: query)
    guard result.rows.count == 1 else { throw NSError(domain: "Probe.Filter", code: 2) }
    return result.rows.count
}
await record("tablepro-not-equal-filter") {
    let filters = [PluginQueryFilter(column: "id", op: "!=", value: "1")]
    guard let query = driver.buildFilteredQuery(
        table: "TableProProbe", schema: "Labels",
        queryFilters: filters,
        logicMode: "and", sortColumns: [], columns: [], limit: 100, offset: 0, columnKinds: ["id": .integer]
    ) else { throw NSError(domain: "Probe.Filter", code: 3) }
    let result = try await driver.execute(query: query)
    let count = try await driver.fetchExactRowCount(
        table: "TableProProbe", schema: "Labels", queryFilters: filters, logicMode: "and"
    )
    guard result.rows.count == 1, count == 1 else { throw NSError(domain: "Probe.Filter", code: 4) }
    return result.rows.count
}
await record("tablepro-unsupported-filter-rejected") {
    guard let query = driver.buildFilteredQuery(
        table: "TableProProbe", schema: "Labels",
        queryFilters: [PluginQueryFilter(column: "name", op: "CONTAINS", value: "Ann", isCaseSensitive: true)],
        logicMode: "and", sortColumns: [], columns: [], limit: 100, offset: 0, columnKinds: ["name": .text]
    ) else { throw NSError(domain: "Probe.Filter", code: 3) }
    do {
        _ = try await driver.execute(query: query)
    } catch {
        return true
    }
    throw NSError(domain: "Probe.Filter", code: 4)
}
await record("tablepro-stream-export") {
    guard let query = driver.defaultExportQuery(table: "TableProProbe", schema: "Labels") else {
        throw NSError(domain: "Probe.Export", code: 1)
    }
    var count = 0
    var columns: [String] = []
    for try await element in driver.streamRows(query: query) {
        switch element {
        case .header(let header): columns = header.columns
        case .rows(let rows): count += rows.count
        }
    }
    guard count == 2, columns.contains("name") else { throw NSError(domain: "Probe.Export", code: 2) }
    return ["columns": columns, "count": count] as [String: Any]
}
if let expected = Int(environment["HYDRADB_PROBE_SCALE"] ?? ""), expected > 1_000 {
    await record("tablepro-sparse-export") {
        guard let query = driver.defaultExportQuery(table: "TableProScale", schema: "Labels") else {
            throw NSError(domain: "Probe.SparseExport", code: 1)
        }
        var count = 0
        var rareIndex: Int?
        var retained = false
        for try await element in driver.streamRows(query: query) {
            switch element {
            case .header(let header): rareIndex = header.columns.firstIndex(of: "rare")
            case .rows(let rows):
                count += rows.count
                if let index = rareIndex, rows.contains(where: { $0[index].asText == "kept" }) {
                    retained = true
                }
            }
        }
        guard count == expected, retained else { throw NSError(domain: "Probe.SparseExport", code: 2) }
        return ["count": count, "rarePropertyRetained": retained] as [String: Any]
    }
}
await record("tablepro-recovery") {
    try await driver.execute(query: "MATCH (n:TableProProbe) RETURN count(*) AS count").rows.count
}
driver.disconnect()
if failures > 0 { exit(1) }
