import Foundation
import TableProMemcachedCore
import TableProPluginKit

// Exercises MemcachedPluginDriver against a live server. Run through check-memcached.sh, which compiles the
// plugin's own sources with this file.

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0
func check(_ ok: Bool, _ label: String) {
    print(ok ? "PASS" : "FAIL", label)
    if !ok { failures += 1 }
}

func texts(_ result: PluginQueryResult) -> [[String?]] {
    result.rows.map { $0.map(\.asText) }
}

let env = ProcessInfo.processInfo.environment
func refusal(user: String, password: String) async -> String? {
    let attempt = MemcachedPluginDriver(config: DriverConnectionConfig(
        host: env["MEMCACHED_HOST"] ?? "127.0.0.1", port: Int(env["MEMCACHED_PORT"] ?? "") ?? 11_211,
        username: user, password: password, database: ""
    ))
    do {
        try await attempt.connect()
        attempt.disconnect()
        return nil
    } catch {
        return error.localizedDescription
    }
}
if env["MEMCACHED_USER"]?.isEmpty ?? true {
    _ = await refusal(user: "probe-user", password: "probe-password")
}
if let user = env["MEMCACHED_USER"], !user.isEmpty {
    let missing = await refusal(user: "", password: "")
    check(missing?.contains("requires a username") == true, "no credentials: \(missing ?? "connected")")
    let wrong = await refusal(user: user, password: "wrong")
    check(wrong?.contains("rejected") == true, "wrong password: \(wrong ?? "connected")")
}
let driver = MemcachedPluginDriver(config: DriverConnectionConfig(
    host: env["MEMCACHED_HOST"] ?? "127.0.0.1",
    port: Int(env["MEMCACHED_PORT"] ?? "") ?? 11_211,
    username: env["MEMCACHED_USER"] ?? "",
    password: env["MEMCACHED_PASSWORD"] ?? "",
    database: ""
))
try await driver.connect()
print("version", driver.serverVersion ?? "nil")
check(driver.serverVersion != nil, "connects and reads the version")

let prefix = "tablepro_probe:"
for index in 0 ..< 30 {
    _ = try await driver.execute(query: "set \(prefix)\(String(format: "%02d", index)) \(index) 0 \"value \(index)\"")
}
_ = try await driver.execute(query: "set \(prefix)ttl 0 600 \"expires\"")
_ = try await driver.execute(query: "set \(prefix)multi 0 0 \"line one\\nline two \\\"quoted\\\"\"")

let tables = try await driver.fetchTables(schema: nil)
print("listing", tables.first?.comment ?? "")
check(tables.map(\.name) == ["keys"], "one keys table")

let condition = try MemcachedBrowseSpec.condition(column: "Key", op: "STARTS WITH", value: prefix, isCaseSensitive: true)
let firstPage = try await driver.execute(query: MemcachedBrowseSpec(
    limit: 10, offset: 0, ascending: true, conditions: [condition]
).statement)
check(firstPage.columns == ["Key", "Value", "TTL", "Flags"], "browse columns")
check(texts(firstPage).first == ["\(prefix)00", "value 0", nil, "0"], "first row sorted by key")
check(firstPage.rows.count == 10, "page of 10")

let thirdPage = try await driver.execute(query: MemcachedBrowseSpec(
    limit: 10, offset: 20, ascending: true, conditions: [condition]
).statement)
check(texts(thirdPage).first?.first == "\(prefix)20", "offset 20 starts at key 20")
check(texts(thirdPage).first?[3] == "20", "flags read back")

let ttlRow = try await driver.execute(query: MemcachedBrowseSpec(limit: 10, offset: 0, ascending: true, conditions: [
    try MemcachedBrowseSpec.condition(column: "Key", op: "=", value: "\(prefix)ttl", isCaseSensitive: true),
]).statement)
let ttl = texts(ttlRow).first?[2].flatMap { Int($0) } ?? 0
check(ttl > 590 && ttl <= 600, "TTL counts down from 600 (\(ttl))")

let multi = try await driver.execute(query: "get \(prefix)multi")
check(texts(multi).first?[1] == "line one\nline two \"quoted\"", "escaped value round-trips")

let refusal = driver.buildFilteredQuery(
    table: "keys", schema: nil, queryFilters: [PluginQueryFilter(column: "Value", op: "=", value: "x")],
    logicMode: "and", sortColumns: [], columns: [], limit: 10, offset: 0, columnKinds: [:]
) ?? ""
do {
    _ = try await driver.execute(query: refusal)
    check(false, "a Value filter is refused")
} catch {
    check("\(error.localizedDescription)".contains("Key"), "a Value filter is refused: \(error.localizedDescription)")
}

let columns = ["Key", "Value", "TTL", "Flags"]
let original: [PluginCellValue] = [.text("\(prefix)05"), .text("value 5"), .null, .text("5")]
let writes = try driver.generateRowWrites(
    table: "keys", schema: nil, columns: columns, primaryKeyColumns: ["Key"],
    changes: [
        PluginRowChange(rowIndex: 0, type: .update, cellChanges: [(1, "Value", .text("value 5"), .text("edited"))], originalRow: original),
        PluginRowChange(rowIndex: 1, type: .update, cellChanges: [(2, "TTL", .null, .text("120"))], originalRow: [
            .text("\(prefix)06"), .text("value 6"), .null, .text("6"),
        ]),
        PluginRowChange(rowIndex: 2, type: .delete, cellChanges: [], originalRow: [.text("\(prefix)07"), .text("value 7"), .null, .text("7")]),
        PluginRowChange(rowIndex: 3, type: .insert, cellChanges: [], originalRow: nil),
    ],
    insertedRowData: [3: [.text("\(prefix)new"), .text("inserted"), .text("60"), .text("9")]],
    deletedRowIndices: [2], insertedRowIndices: [3]
) ?? []
for write in writes { _ = try await driver.execute(query: write.statement) }
let afterWrites = try await driver.execute(query: "get \(prefix)05 \(prefix)06 \(prefix)07 \(prefix)new")
let byKey = Dictionary(uniqueKeysWithValues: texts(afterWrites).map { ($0[0] ?? "", $0) })
check(byKey["\(prefix)05"]?[1] == "edited" && byKey["\(prefix)05"]?[2] == "5", "set keeps flags")
check(byKey["\(prefix)06"]?[1] == "value 6", "touch keeps the value")
check(byKey["\(prefix)07"] == nil, "delete removes the key")
check(byKey["\(prefix)new"]?[1] == "inserted" && byKey["\(prefix)new"]?[2] == "9", "insert sets value and flags")
// A metadump walks the LRU while the server moves items between its segments, so an item bumped by the touch can
// be missed by one walk and listed by the next.
var ttls: [Int] = []
for _ in 0 ..< 5 where ttls.count < 2 {
    let touched = try await driver.execute(query: MemcachedBrowseSpec(limit: 10, offset: 0, ascending: true, conditions: [
        try MemcachedBrowseSpec.condition(column: "Key", op: "IN", value: "\(prefix)06,\(prefix)new", isCaseSensitive: true),
    ]).statement)
    ttls = texts(touched).map { Int($0[2] ?? "") ?? -1 }
}
check(ttls.count == 2 && ttls[0] > 110 && ttls[0] <= 120 && ttls[1] > 50 && ttls[1] <= 60, "TTLs from touch and insert \(ttls)")

let incr = try await driver.execute(query: "set \(prefix)counter 0 0 \"41\"")
check(texts(incr).first?.first == "STORED", "set replies STORED")
let counted = try await driver.execute(query: "incr \(prefix)counter 1")
check(texts(counted).first?.first == "42", "incr replies the new value")
let stats = try await driver.execute(query: "stats")
check(stats.columns == ["Name", "Value"] && texts(stats).contains { $0.first == "curr_items" }, "stats as a grid")
do {
    let metadump = try await driver.execute(query: "lru_crawler metadump all")
    check(metadump.rows.count >= 30, "metadump lists the probe's keys (\(metadump.rows.count) rows)")
} catch {
    check(tables.first?.comment?.contains("cachedump") == true, "metadump refused where the listing uses cachedump: \(error.localizedDescription)")
}
do {
    _ = try await driver.execute(query: "set bad key 0 0 v")
    check(false, "a bad statement is refused")
} catch {
    check(true, "a bad statement is refused: \(error.localizedDescription)")
}
let leaked = try await driver.execute(query: "get tablepro")
check(leaked.rows.isEmpty, "credentials given to an open server are not stored as an item")
let reset = try await driver.execute(query: "stats reset")
check(texts(reset).first?.first == "RESET", "stats reset answers one status line")
let quotedKey = "\(prefix)it's \"quoted\""
let quotedWrites = try driver.generateRowWrites(
    table: "keys", schema: nil, columns: columns, primaryKeyColumns: ["Key"],
    changes: [PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)],
    insertedRowData: [0: [.text(quotedKey.replacingOccurrences(of: " ", with: "_")), .text("q"), .null, .null]],
    deletedRowIndices: [], insertedRowIndices: [0]
) ?? []
for write in quotedWrites { _ = try await driver.execute(query: write.statement) }
let quotedRead = try await driver.execute(query: "get \(MemcachedCommandParser.argument(quotedKey.replacingOccurrences(of: " ", with: "_")))")
check(texts(quotedRead).first?[1] == "q", "a key with quotes is written and read back")
let notStored = try await driver.execute(query: "add \(prefix)00 0 0 \"x\"")
check(texts(notStored).first?.first == "NOT_STORED", "add on an existing key replies NOT_STORED")

let keys = try await driver.execute(query: MemcachedBrowseSpec(
    limit: 100, offset: 0, ascending: true, conditions: [condition]
).statement)
for row in texts(keys) { _ = try await driver.execute(query: MemcachedStatements.delete(key: row[0] ?? "")) }
try await driver.ping()
driver.disconnect()

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
