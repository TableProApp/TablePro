import Foundation
import TableProPluginKit

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private enum NulTextProbe {
    static let key = "ké\u{0}一"
    static let shortKey = "ké"
    static let value = "café\u{0}尾"
    static let edited = "été\u{0}終"

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeFailure(description: message) }
    }

    static func texts(_ rows: [PluginRow]) -> [[String?]] {
        rows.map { $0.map(\.asText) }
    }

    static func streamed(_ driver: any PluginDatabaseDriver, _ query: String) async throws -> [[String?]] {
        var rows: [PluginRow] = []
        for try await item in driver.streamRows(query: query) {
            if case .rows(let batch) = item { rows.append(contentsOf: batch) }
        }
        return texts(rows)
    }

    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let database = directory.appendingPathComponent("nul-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: database) }
        let config = DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: database.path,
            additionalFields: ["libsqlMode": "local", "libsqlFilePath": database.path]
        )
        #if BEANCOUNT
        try await beancount(config, ledger: database)
        #else
        #if LIBSQL
        let driver = LibSQLPluginDriver(
            config: config, localDatabaseRuntime: LibSQLProductionLocalDatabaseRuntime()
        )
        #else
        let driver = DuckDBPluginDriver(config: config)
        #endif
        try await driver.connect()
        defer { driver.disconnect() }
        try await roundTrip(driver)
        #if DUCKDB
        try await mixedDuckDBResults(driver)
        try await duckDBSessionResults(driver)
        try await duckDBLifecycle(directory: directory)
        #endif
        #endif
        print("PASS: NUL insert, read, stream and key checks")
    }

    static func roundTrip(_ driver: any PluginDatabaseDriver) async throws {
        _ = try await driver.execute(query: "CREATE TABLE notes (id VARCHAR PRIMARY KEY, body VARCHAR)")
        _ = try await driver.executeParameterized(
            query: "INSERT INTO notes VALUES (?, ?), (?, 'other')",
            parameters: [.text(key), .text(value), .text(shortKey)]
        )
        let read = try await driver.execute(query: "SELECT id, body FROM notes ORDER BY id")
        try expect(texts(read.rows) == [[shortKey, "other"], [key, value]], "bound insert/read cut text")
        try expect(try await streamed(driver, "SELECT id, body FROM notes ORDER BY id") == texts(read.rows), "stream cut text")
        guard let readKey = read.rows.last?.first?.asText else { throw ProbeFailure(description: "missing key") }
        _ = try await driver.executeParameterized(
            query: "UPDATE notes SET body = ? WHERE id = ?", parameters: [.text(edited), .text(readKey)]
        )
        let after = try await driver.execute(query: "SELECT id, body FROM notes ORDER BY id")
        try expect(texts(after.rows) == [[shortKey, "other"], [key, edited]], "edit changed the wrong row or cut text")
        for sample in ["", "\u{0}", "\u{0}é", "é\u{0}", "a\u{0}b\u{0}c", String(repeating: "é", count: 32) + "\u{0}尾"] {
            let result = try await driver.executeParameterized(query: "SELECT ?", parameters: [.text(sample)])
            try expect(texts(result.rows) == [[sample]], "text boundary round-trip failed")
        }
    }

    #if DUCKDB
    static func mixedDuckDBResults(_ driver: any PluginDatabaseDriver) async throws {
        _ = try await driver.execute(query: "CREATE TABLE mixed (v VARCHAR, d DATE, f DOUBLE, n DECIMAL(10,2), edits INTEGER)")
        let columns = "v, d, f, n, edits"
        let expected: [[String?]] = [[value, "2024-01-01", "1.5", "12.30", "0"]]
        let insert = "INSERT INTO mixed VALUES (?, DATE '2024-01-01', 1.5, 12.30, 0) RETURNING \(columns)"
        let result = try await driver.executeParameterized(query: insert, parameters: [.text(value)])
        try expect(texts(result.rows) == expected, "mixed INSERT RETURNING cut text or changed a type")
        try expect(result.rowsAffected == 1, "mixed INSERT RETURNING reported the wrong count")
        let select = try await driver.execute(query: "SELECT \(columns) FROM mixed")
        try expect(texts(select.rows) == expected, "mixed SELECT cut text or changed a type")
        try expect(select.rowsAffected == 0, "SELECT reported changed rows")
        try expect(try await streamed(driver, "SELECT \(columns) FROM mixed") == expected, "mixed SELECT stream failed")
        let update = try await driver.executeParameterized(
            query: "UPDATE mixed SET v = ?, edits = edits + 1 RETURNING \(columns)", parameters: [.text(edited)]
        )
        try expect(texts(update.rows) == [[edited, "2024-01-01", "1.5", "12.30", "1"]], "mixed UPDATE RETURNING failed")
        try expect(update.rowsAffected == 1, "mixed UPDATE RETURNING reported the wrong count")
        let streamedInsert = "INSERT INTO mixed VALUES ('café'||chr(0)||'尾', DATE '2024-01-01', 1.5, 12.30, 0) RETURNING \(columns)"
        try expect(try await streamed(driver, streamedInsert) == expected, "mixed INSERT RETURNING stream failed")
        let streamedUpdate = "UPDATE mixed SET edits = edits + 1 WHERE edits = 0 RETURNING \(columns)"
        try expect(
            try await streamed(driver, streamedUpdate) == [[value, "2024-01-01", "1.5", "12.30", "1"]],
            "mixed UPDATE RETURNING stream failed"
        )
        let counts = try await driver.execute(query: "SELECT count(*), sum(edits) FROM mixed")
        try expect(texts(counts.rows) == [["2", "2"]], "a mutation ran more than once")
        try expect(counts.rowsAffected == 0, "aggregate SELECT reported changed rows")
        _ = try await driver.execute(query: "CREATE TABLE nested (v VARCHAR, items INTEGER[], id UUID)")
        let uuid = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
        let nestedInsert = try await driver.executeParameterized(
            query: "INSERT INTO nested VALUES (?, [1, NULL, 3], ?::UUID) RETURNING v, items, id",
            parameters: [.text(value), .text(uuid)]
        )
        try expect(texts(nestedInsert.rows) == [[value, "[1, NULL, 3]", uuid]], "nested INSERT RETURNING changed values")
        try expect(nestedInsert.rowsAffected == 1, "nested INSERT RETURNING reported the wrong count")
        let nestedUpdate = "UPDATE nested SET v = 'été'||chr(0)||'終' RETURNING v, items, id"
        try expect(
            try await streamed(driver, nestedUpdate) == [[edited, "[1, NULL, 3]", uuid]],
            "nested UPDATE RETURNING stream changed values"
        )
        let updatedNested = try await driver.execute(query: nestedUpdate)
        try expect(updatedNested.rowsAffected == 1, "nested UPDATE RETURNING reported the wrong count")
        let deleted = try await driver.execute(query: "DELETE FROM nested RETURNING v, items, id")
        try expect(texts(deleted.rows) == [[edited, "[1, NULL, 3]", uuid]], "DELETE RETURNING changed values")
        try expect(deleted.rowsAffected == 1, "DELETE RETURNING reported the wrong count")
        for statement in [
            "UPDATE nested SET v = 'none' RETURNING v, items, id",
            "DELETE FROM nested RETURNING v, items, id",
            "UPDATE nested SET v = 'none'",
            "DELETE FROM nested",
        ] {
            let emptyMutation = try await driver.execute(query: statement)
            try expect(emptyMutation.rowsAffected == 0, "empty mutation reported changed rows: \(statement)")
        }
        let ordinaryInsert = try await driver.execute(query: "INSERT INTO nested VALUES ('one', [], NULL), ('two', [], NULL)")
        try expect(ordinaryInsert.rowsAffected == 2, "ordinary INSERT reported the wrong count")
        let count = try await driver.execute(query: "SELECT count(*) FROM nested")
        try expect(texts(count.rows) == [["2"]] && count.rowsAffected == 0, "SELECT count reported changed rows")
    }

    static func duckDBSessionResults(_ driver: any PluginDatabaseDriver) async throws {
        let empty = try await driver.execute(query: """
            SELECT 'a'||chr(0)||'b' AS value, DATE '2024-01-01' AS day, [1, 2] AS items WHERE false
            """)
        try expect(empty.columns == ["value", "day", "items"] && empty.rows.isEmpty, "empty result lost its schema")
        let query = """
            SELECT 'a'||chr(0)||'b' AS same, NULL::DATE AS same, [1, NULL, 3] AS same, {'x': 1} AS object
            """
        let nested = try await driver.execute(query: query)
        try expect(nested.columns == ["same", "same", "same", "object"], "duplicate column names changed")
        try expect(texts(nested.rows) == [["a\u{0}b", nil, "[1, NULL, 3]", "{'x': 1}"]], "NULL or nested values changed")
        try expect(try await streamed(driver, query) == texts(nested.rows), "nested stream changed values")
        _ = try await driver.execute(query: "BEGIN")
        let inside = try await driver.execute(query: query)
        try expect(texts(inside.rows) == texts(nested.rows), "result reader failed inside a transaction")
        _ = try await driver.execute(query: "ROLLBACK")
        let after = try await driver.execute(query: query)
        try expect(texts(after.rows) == texts(nested.rows), "result reader failed after rollback")
        _ = try await driver.execute(query: "CREATE SCHEMA nul_schema")
        _ = try await driver.execute(query: "USE nul_schema")
        let moved = try await driver.execute(query: query)
        try expect(texts(moved.rows) == texts(nested.rows), "result reader failed after USE")
        _ = try await driver.execute(query: "USE main")
    }

    static func duckDBLifecycle(directory: URL) async throws {
        let file = directory.appendingPathComponent("reader-\(UUID().uuidString).duckdb")
        defer { try? FileManager.default.removeItem(at: file) }
        let live = DuckDBLiveConnectionBox()
        let actor = DuckDBConnectionActor(liveConnection: live)
        try await actor.open(spec: DuckDBOpenSpec(path: file.path, accessMode: .readWrite))
        do {
            _ = try await actor.executeQuery("CREATE TABLE saved AS SELECT 'a'||chr(0)||'b' AS v, DATE '2024-01-01' AS d")
            await actor.captureSettingsBaseline()
            let query = "SELECT v, d FROM saved"
            let expected: [[String?]] = [["a\u{0}b", "2024-01-01"]]
            let readOnly = try await actor.executeReadOnly(query, parameters: [])
            try expect(texts(readOnly.rows) == expected, "read-only transaction failed to render text")
            let following = try await actor.executeQuery(query)
            try expect(texts(following.rows) == expected, "read-only rollback lost the reader")
            _ = try await actor.executeQuery("PREPARE retained_query AS SELECT v, d FROM saved")
            let held = await actor.releaseFile(idleFor: nil)
            try expect(held == .holdsSessionObjects, "release discarded a user prepared statement")
            _ = try await actor.executeQuery("DEALLOCATE retained_query")
            let released = await actor.releaseFile(idleFor: nil)
            if released != .released {
                let functions = try await actor.executeQuery(
                    "SELECT function_name, internal FROM duckdb_functions() WHERE function_name LIKE '_tablepro_result_%'"
                )
                let state = try await actor.executeQuery(DuckDBSchemaQueries.sessionHeldState)
                let prepared = try await actor.executeQuery("SELECT name FROM duckdb_prepared_statements()")
                throw ProbeFailure(description: "reader prevented idle release: \(released); functions: \(texts(functions.rows)); held: \(texts(state.rows)); prepared: \(texts(prepared.rows))")
            }
            try expect(await actor.hasReleasedFile, "release did not close the file")
            let reopened = try await actor.executeQuery(query)
            try expect(texts(reopened.rows) == expected, "reopen did not restore the reader")
            live.interrupt()
            let fresh = try await actor.executeQuery(query)
            try expect(texts(fresh.rows) == expected, "fresh query failed after idle interrupt")
            await actor.close()
        } catch {
            await actor.close()
            throw error
        }

        let readOnlyDriver = DuckDBPluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: file.path,
            additionalFields: [DuckDBAccessMode.fieldId: "true"]
        ))
        try await readOnlyDriver.connect()
        defer { readOnlyDriver.disconnect() }
        let read = try await readOnlyDriver.execute(query: "SELECT v, d FROM saved")
        try expect(texts(read.rows) == [["a\u{0}b", "2024-01-01"]], "read-only file failed to render text")
    }
    #endif

    #if BEANCOUNT
    static func beancount(_ config: DriverConnectionConfig, ledger: URL) async throws {
        let driver = BeancountPluginDriver(config: config)
        defer { driver.disconnect() }
        var projection = BeancountProjectionRows()
        projection.accounts = [
            ["account": shortKey, "booking": "other"],
            ["account": key, "booking": value],
        ]
        driver.installProjection(try BeancountPluginDriver.loadProjection(rows: projection, sourceFiles: []), ledgerURL: ledger)
        let query = "SELECT name, booking FROM accounts ORDER BY name"
        let read = try await driver.execute(query: query)
        try expect(texts(read.rows) == [[shortKey, "other"], [key, value]], "projection insert/read cut text")
        try expect(try await streamed(driver, query) == texts(read.rows), "projection stream cut text")
        guard let readKey = read.rows.last?.first?.asText else { throw ProbeFailure(description: "missing key") }
        let matched = try await driver.executeParameterized(
            query: "SELECT name, booking FROM accounts WHERE name = ?", parameters: [.text(readKey)]
        )
        try expect(texts(matched.rows) == [[key, value]], "bound key selected the wrong account")
        do {
            _ = try await driver.executeParameterized(
                query: "UPDATE accounts SET booking = ? WHERE name = ?", parameters: [.text(edited), .text(readKey)]
            )
            throw ProbeFailure(description: "read-only projection accepted an edit")
        } catch BeancountDriverError.readOnly {
            let unchanged = try await driver.execute(query: query)
            try expect(texts(unchanged.rows) == texts(read.rows), "refused edit changed projection")
        }
        // Reloads replace accounts by primary key, so a cut key would overwrite the competing account.
        projection.accounts.append(["account": readKey, "booking": edited])
        driver.installProjection(try BeancountPluginDriver.loadProjection(rows: projection, sourceFiles: []), ledgerURL: ledger)
        let after = try await driver.execute(query: query)
        try expect(texts(after.rows) == [[shortKey, "other"], [key, edited]], "projection replacement matched the wrong key")
    }
    #endif
}
