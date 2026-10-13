import Foundation
import TableProFirebaseCore
import TableProPluginKit
import Testing

private func makeDriver(realtimeDatabase: Bool = false, fields extra: [String: String] = [:]) -> FirebasePluginDriver {
    var fields = extra
    if realtimeDatabase { fields[FirebaseFieldID.driverVariant] = FirebaseVariant.realtimeDatabase.rawValue }
    return FirebasePluginDriver(config: DriverConnectionConfig(
        host: "", port: 0, username: "", password: "", database: "", additionalFields: fields
    ))
}

private func change(
    _ type: PluginRowChange.ChangeType,
    row: Int = 0,
    cells: [(Int, String, PluginCellValue)] = [],
    original: [PluginCellValue]? = nil,
    absent: Set<Int>? = nil
) -> PluginRowChange {
    var change = PluginRowChange(
        rowIndex: row,
        type: type,
        cellChanges: cells.map { (columnIndex: $0.0, columnName: $0.1, oldValue: PluginCellValue.null, newValue: $0.2) },
        originalRow: original
    )
    change.absentColumns = absent
    return change
}

private func statements(
    _ driver: FirebasePluginDriver,
    table: String,
    columns: [String],
    changes: [PluginRowChange],
    inserted: [Int: [PluginCellValue]] = [:],
    hostTypes: [String: String] = [:]
) throws -> [String] {
    var context = PluginRowWriteContext()
    context.columnTypeNames = hostTypes
    return try driver.generateRowWrites(
        table: table, schema: nil, columns: columns, primaryKeyColumns: [],
        changes: changes, insertedRowData: inserted,
        deletedRowIndices: Set(changes.filter { $0.type == .delete }.map(\.rowIndex)),
        insertedRowIndices: Set(changes.filter { $0.type == .insert }.map(\.rowIndex)),
        context: context
    )?.map(\.statement) ?? []
}

private func restore(
    _ driver: FirebasePluginDriver,
    table: String,
    columns: [String],
    rows: [[PluginCellValue]],
    absent: [Int: Set<Int>] = [:]
) -> [String]? {
    driver.generateIdentityPreservingInsert(
        table: table, schema: nil, columns: columns, primaryKeyColumns: [], rows: rows, absentCells: absent
    )?.map(\.statement)
}

struct FirebaseFirestoreWriteTests {
    private let columns = ["__name__", "age", "name", "zip"]

    @Test("An edit is typed by the value it replaces and masked to the fields it touches")
    func typedUpdate() throws {
        let driver = makeDriver()
        driver.rememberCellTypes(["users/alice": ["age": "integer", "zip": "string"]])
        let written = try statements(driver, table: "users", columns: columns, changes: [
            change(.update, cells: [(1, "age", .text("31")), (3, "zip", .text("02134"))],
                   original: [.text("alice"), .text("30"), .text("Alice"), .text("02100")])
        ])
        #expect(written == [#"PATCH users/alice?updateMask=age,zip {"age":31,"zip":"02134"}"#])
    }

    @Test("A removed field is in the mask and not in the body")
    func fieldRemoval() throws {
        let written = try statements(makeDriver(), table: "users", columns: columns, changes: [
            change(.update, original: [.text("alice"), .text("30"), .null, .null], absent: [2])
        ])
        #expect(written == [#"PATCH users/alice?updateMask=name {}"#])
    }

    @Test("A new row picks its ID from __name__, or lets Firestore pick one")
    func inserts() throws {
        let driver = makeDriver()
        driver.rememberColumnTypes("users", columns: columns, types: ["string", "integer", "string", "string"])
        let named = try statements(driver, table: "users", columns: columns, changes: [change(.insert, row: 0, absent: [3])],
                                   inserted: [0: [.text("bob"), .text("40"), .text("Bob"), .null]])
        #expect(named == [#"POST users?documentId=bob {"age":40,"name":"Bob"}"#])
        let anonymous = try statements(driver, table: "users/alice/orders", columns: ["__name__", "total"],
                                       changes: [change(.insert, row: 1)], inserted: [1: [.text(""), .text("9.5")]])
        #expect(anonymous == [#"POST users/alice/orders {"total":9.5}"#])
    }

    @Test("A delete names the document by its path, and a group row by its full path")
    func deletes() throws {
        #expect(try statements(makeDriver(), table: "users", columns: columns, changes: [
            change(.delete, original: [.text("alice"), .null, .null, .null])
        ]) == ["DELETE users/alice"])
        #expect(try statements(makeDriver(), table: "*/orders", columns: ["__name__"], changes: [
            change(.delete, original: [.text("users/alice/orders/7")])
        ]) == ["DELETE users/alice/orders/7"])
    }

    @Test("A value that does not fit the field is refused with the reason, not dropped")
    func refusal() {
        let driver = makeDriver()
        driver.rememberCellTypes(["users/alice": ["age": "integer"]])
        #expect(throws: PluginRowWriteRefusal.self) {
            try statements(driver, table: "users", columns: columns, changes: [
                change(.update, cells: [(1, "age", .text("old"))], original: [.text("alice"), .text("30"), .null, .null])
            ])
        }
        #expect(throws: PluginRowWriteRefusal.self) {
            try statements(driver, table: "*/orders", columns: ["__name__", "total"],
                           changes: [change(.insert)], inserted: [0: [.text("7"), .text("1")]])
        }
    }

    @Test("With nothing read on this connection, the host's column types type the edit")
    func hostTypes() throws {
        let edit = change(.update, cells: [(3, "zip", .text("123"))], original: [.text("alice"), .null, .null, .text("100")])
        #expect(try statements(makeDriver(), table: "users", columns: columns, changes: [edit], hostTypes: ["zip": "STRING"])
            == [#"PATCH users/alice?updateMask=zip {"zip":"123"}"#])
        #expect(try statements(makeDriver(), table: "users", columns: columns, changes: [edit])
            == [#"PATCH users/alice?updateMask=zip {"zip":123}"#])
    }

    @Test("A field that held null is typed by its column, not left to guessing")
    func nullCell() throws {
        let driver = makeDriver()
        driver.rememberColumnTypes("users", columns: columns, types: ["string", "integer", "string", "string"])
        driver.rememberCellTypes(["users/alice": ["zip": "null"]])
        #expect(try statements(driver, table: "users", columns: columns, changes: [
            change(.update, cells: [(3, "zip", .text("12345"))], original: [.text("alice"), .null, .null, .null])
        ]) == [#"PATCH users/alice?updateMask=zip {"zip":"12345"}"#])
    }

    @Test("An ID or field name the request line would split is escaped or quoted")
    func awkwardNames() throws {
        let written = try statements(makeDriver(), table: "users", columns: ["__name__", "a,b"], changes: [
            change(.update, cells: [(1, "a,b", .text("x"))], original: [.text("John Smith"), .null]),
            change(.delete, row: 1, original: [.text("a&b=c"), .null])
        ])
        #expect(written == [#"PATCH users/John%20Smith?updateMask=`a,b` {"a,b":"x"}"#, "DELETE users/a%26b%3Dc"])
        guard case .request(let patch) = try FirebaseStatement.parse(written[0]) else {
            Issue.record("Expected a request line")
            return
        }
        #expect(patch.path == "users/John Smith")
        #expect(patch.queryValue("updateMask").map(FirestoreQueryBuilder.maskFields) == ["a,b"])
    }

    @Test("Undoing a delete restores the ID, leaves out missing fields, and types each value by its own field")
    func restoreDeleted() throws {
        let driver = makeDriver()
        let columns = ["__name__", "age", "name", "zip", "tags"]
        driver.rememberColumnTypes("users", columns: columns, types: ["string", "integer", "string", "integer", "array"])
        driver.rememberCellTypes(["users/alice": ["age": "integer", "zip": "string"]])
        let restored = restore(driver, table: "users", columns: columns,
                               rows: [[.text("alice"), .text("30"), .null, .text("02134"), .null]], absent: [0: [2, 4]])
        #expect(restored == [#"POST users?documentId=alice {"age":30,"zip":"02134"}"#])
        #expect(restore(driver, table: "users", columns: columns, rows: [[.text(""), .text("1"), .null, .null, .null]]) == nil)
    }

    @Test("A new row's __name__ is an ID in this collection, never a path elsewhere")
    func insertStaysInCollection() {
        #expect(throws: PluginRowWriteRefusal.self) {
            try statements(makeDriver(), table: "users", columns: ["__name__", "n"],
                           changes: [change(.insert)], inserted: [0: [.text("admins/root"), .text("1")]])
        }
    }

    @Test("A whole document carries its path and refuses a rename")
    func documents() throws {
        let driver = makeDriver()
        let text = FirebasePluginDriver.documentText(path: "users/alice", fields: ["age": .integer(30)])
        let edited = text.replacingOccurrences(of: "30", with: "31")
        #expect(try driver.documentWriteStatement(PluginDocumentWrite(
            table: "users", schema: nil, operation: .replace(original: text, edited: edited)
        )) == #"PATCH users/alice {"age":31}"#)
        let renamed = edited.replacingOccurrences(of: "users/alice", with: "users/bob")
        #expect(throws: FirebaseError.self) {
            try driver.documentWriteStatement(PluginDocumentWrite(table: "users", schema: nil, operation: .replace(original: text, edited: renamed)))
        }
        #expect(try driver.documentWriteStatement(PluginDocumentWrite(
            table: "users", schema: nil, operation: .insert(document: #"{"__name__": "carol", "when": {"$timestamp": "2026-10-12T08:00:00Z"}}"#)
        )) == #"POST users?documentId=carol {"when":{"$timestamp":"2026-10-12T08:00:00Z"}}"#)
    }

    @Test("Filters travel in the browse statement")
    func browseStatement() throws {
        let statement = try #require(makeDriver().buildFilteredQuery(
            table: "users", schema: nil,
            queryFilters: [PluginQueryFilter(column: "age", op: ">", value: "3", secondValue: nil, elementScope: nil)],
            logicMode: "OR", sortColumns: [(columnIndex: 1, ascending: false)],
            columns: columns, limit: 50, offset: 100, columnKinds: [:]
        ))
        guard case .browse(let spec) = try FirebaseStatement.parse(statement) else {
            Issue.record("Expected a browse statement")
            return
        }
        #expect(spec == FirebaseBrowseSpec(table: "users", filters: [FirebaseFilterSpec(column: "age", op: ">", value: "3")],
                                           logicMode: "OR", sorts: [FirebaseSortSpec(column: "age", ascending: false)], limit: 50, offset: 100))
    }

    @Test("Export moves fields outside the first page's columns into __extra__")
    func exportAlignment() {
        let aligned = FirebasePluginDriver.align(
            [.text("bob"), .text("x"), .text("1")], columns: ["__name__", "late", "age"], to: ["__name__", "age", "__extra__"]
        )
        #expect(aligned == [.text("bob"), .text("1"), .text(#"{"late":"x"}"#)])
    }
}

struct FirebaseRealtimeDatabaseWriteTests {
    private let columns = ["$key", "calls", "name", "$value"]

    @Test("Child edits patch the child, typed by the cell, and a removal writes null")
    func update() throws {
        let driver = makeDriver(realtimeDatabase: true)
        driver.rememberCellTypes(["operators/op_1": ["calls": "number", "name": "string"]])
        let written = try statements(driver, table: "operators", columns: columns, changes: [
            change(.update, cells: [(1, "calls", .text("4"))], original: [.text("op_1"), .text("3"), .text("Ann"), .null], absent: [2])
        ])
        #expect(written == [#"PATCH operators/op_1 {"calls":4,"name":null}"#])
    }

    @Test("A plain node's row is the node itself, and a child with the node's name is still a child")
    func plainValues() throws {
        let driver = makeDriver(realtimeDatabase: true)
        let hostTypes = ["$value": "boolean"]
        let node = try statements(driver, table: "maintenance", columns: ["$key", "$value"], changes: [
            change(.update, cells: [(1, "$value", .text("true"))], original: [.text("/maintenance"), .text("false")])
        ], hostTypes: hostTypes)
        #expect(node == ["PUT maintenance true"])
        let child = try statements(driver, table: "maintenance", columns: ["$key", "$value"], changes: [
            change(.update, cells: [(1, "$value", .text("true"))], original: [.text("maintenance"), .text("false")])
        ], hostTypes: hostTypes)
        #expect(child == ["PUT maintenance/maintenance true"])
    }

    @Test("Undoing a delete puts a child back under its key, and a plain node back in place")
    func restoreDeleted() {
        let driver = makeDriver(realtimeDatabase: true)
        driver.rememberCellTypes(["config/maintenance": ["$value": "boolean"], "operators/op_1": ["calls": "number"]])
        #expect(restore(driver, table: "config/maintenance", columns: ["$key", "$value"], rows: [[.text("/config/maintenance"), .text("false")]])
            == ["PUT config/maintenance false"])
        #expect(restore(driver, table: "operators", columns: ["$key", "calls", "$value"],
                        rows: [[.text("op_1"), .text("3"), .null]], absent: [0: [2]]) == [#"PUT operators/op_1 {"calls":3}"#])
        #expect(restore(driver, table: "operators", columns: ["$key", "calls"], rows: [[.text(""), .text("3")]]) == nil)
    }

    @Test("Replacing or deleting the whole database is refused before anything is sent")
    func wholeDatabase() async {
        let driver = makeDriver(realtimeDatabase: true)
        for statement in ["PUT / null", "PUT / {}", "DELETE /"] {
            do {
                _ = try await driver.execute(query: statement)
                Issue.record("Expected \(statement) to be refused")
            } catch let error as FirebaseError {
                guard case .unsupported = error else {
                    Issue.record("Expected a refusal for \(statement), got \(error)")
                    continue
                }
            } catch {
                Issue.record("Unexpected \(error)")
            }
        }
    }

    @Test("New children go under their key, or a generated one, and empty ones are refused")
    func inserts() throws {
        let driver = makeDriver(realtimeDatabase: true)
        #expect(try statements(driver, table: "/", columns: columns, changes: [change(.insert)],
                               inserted: [0: [.text("op_9"), .text("0"), .text("Zed"), .null]]) == [#"PUT op_9 {"calls":0,"name":"Zed"}"#])
        #expect(try statements(driver, table: "chats", columns: ["$key", "$value"], changes: [change(.insert)],
                               inserted: [0: [.text(""), .text("hello")]]) == [#"POST chats "hello""#])
        #expect(throws: PluginRowWriteRefusal.self) {
            try statements(driver, table: "chats", columns: ["$key", "$value"], changes: [change(.insert)], inserted: [0: [.text("a.b"), .text("1")]])
        }
        #expect(throws: PluginRowWriteRefusal.self) {
            try statements(driver, table: "chats", columns: ["$key", "$value"], changes: [change(.insert)], inserted: [0: [.text("k"), .null]])
        }
    }

    @Test("A node is edited as $key and $value, and bare JSON is pushed")
    func documents() throws {
        let driver = makeDriver(realtimeDatabase: true)
        let text = FirebasePluginDriver.nodeText(path: "operators/op_1", value: .object(["calls": .int(3)]))
        #expect(try driver.documentWriteStatement(PluginDocumentWrite(
            table: "operators", schema: nil, operation: .replace(original: text, edited: text.replacingOccurrences(of: "3", with: "5"))
        )) == #"PUT operators/op_1 {"calls":5}"#)
        #expect(try driver.documentWriteStatement(PluginDocumentWrite(
            table: "operators", schema: nil, operation: .insert(document: #"{"calls": 1}"#)
        )) == #"POST operators {"calls":1}"#)
    }
}

/// Drives the whole driver against the Firebase emulators when their standard variables are set.
private enum EmulatorHosts {
    static let firestore = ProcessInfo.processInfo.environment["FIRESTORE_EMULATOR_HOST"]
    static let database = ProcessInfo.processInfo.environment["FIREBASE_DATABASE_EMULATOR_HOST"]
}

@Suite(.enabled(if: EmulatorHosts.firestore != nil && EmulatorHosts.database != nil), .serialized)
struct FirebaseDriverEmulatorTests {
    @Test("Firestore: connect, write from the grid, browse, filter, count and guard a stale edit")
    func firestore() async throws {
        let driver = makeDriver(fields: [
            FirebaseFieldID.authMethod: "emulator", FirebaseFieldID.projectId: "demo-tablepro",
            FirebaseFieldID.emulatorHost: try #require(EmulatorHosts.firestore)
        ])
        try await driver.connect()
        let table = "drv_\(UUID().uuidString.prefix(6))"
        _ = try await driver.execute(query: #"POST \#(table)?documentId=alice {"age": 30, "name": "Alice"}"#)
        _ = try await driver.execute(query: #"POST \#(table)?documentId=bob {"age": 40}"#)
        #expect(try await driver.fetchTables(schema: nil).map(\.name).contains(table))

        let page = try await driver.execute(query: try #require(driver.buildBrowseQuery(
            table: table, sortColumns: [], columns: [], limit: 10, offset: 0
        )))
        #expect(page.columns == ["__name__", "age", "name"])
        #expect(page.rowLocators == ["\(table)/alice", "\(table)/bob"])
        #expect(page.absentCells == [1: [2]])

        let filtered = try await driver.execute(query: try #require(driver.buildFilteredQuery(
            table: table, schema: nil,
            queryFilters: [PluginQueryFilter(column: "age", op: ">=", value: "35", secondValue: nil, elementScope: nil)],
            logicMode: "AND", sortColumns: [], columns: page.columns, limit: 10, offset: 0, columnKinds: [:]
        )))
        #expect(filtered.rows.map { $0[0] } == [.text("bob")])
        #expect(try await driver.fetchExactRowCount(table: table, schema: nil, queryFilters: [], logicMode: "AND") == 2)

        let original = try #require(try await driver.fetchDocument(table: table, schema: nil, locator: "\(table)/alice"))
        _ = try await driver.execute(query: #"PATCH \#(table)/alice?updateMask=age {"age": 31}"#)
        await #expect(throws: FirebaseError.self) {
            try await driver.executeDocumentWrite(PluginDocumentWrite(
                table: table, schema: nil, operation: .replace(original: original, edited: original.replacingOccurrences(of: "Alice", with: "Ally"))
            ))
        }
        _ = try await driver.execute(query: "DELETE \(table)/alice")
        _ = try await driver.execute(query: "DELETE \(table)/bob")
        driver.disconnect()
    }

    @Test("Realtime Database: connect, write, browse in key order and guard a stale node edit")
    func realtimeDatabase() async throws {
        let driver = makeDriver(realtimeDatabase: true, fields: [
            FirebaseFieldID.authMethod: "emulator", FirebaseFieldID.projectId: "demo-tablepro",
            FirebaseFieldID.emulatorHost: try #require(EmulatorHosts.database)
        ])
        try await driver.connect()
        let node = "drv_\(UUID().uuidString.prefix(6))"
        _ = try await driver.execute(query: #"PUT \#(node) {"b": {"n": 2}, "a": {"n": 1}, "c": "plain"}"#)
        let page = try await driver.execute(query: try #require(driver.buildBrowseQuery(table: node, sortColumns: [], columns: [], limit: 2, offset: 1)))
        #expect(page.columns == ["$key", "n", "$value"])
        #expect(page.rows.map { $0[0] } == [.text("b"), .text("c")])
        #expect(try await driver.fetchExactRowCount(table: node, schema: nil, queryFilters: [], logicMode: "AND") == 3)

        let original = try #require(try await driver.fetchDocument(table: node, schema: nil, locator: "\(node)/a"))
        try await driver.executeDocumentWrite(PluginDocumentWrite(
            table: node, schema: nil, operation: .replace(original: original, edited: original.replacingOccurrences(of: "\"n\": 1", with: "\"n\": 10"))
        ))
        await #expect(throws: FirebaseError.self) {
            try await driver.executeDocumentWrite(PluginDocumentWrite(
                table: node, schema: nil, operation: .replace(original: original, edited: original)
            ))
        }
        _ = try await driver.execute(query: "DELETE \(node)")
        driver.disconnect()
    }
}
