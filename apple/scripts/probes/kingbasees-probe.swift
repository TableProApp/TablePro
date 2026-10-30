import Foundation
import TableProPluginKit
import TableProSQLGrammar

@main
struct KingbaseESProbe {
    var passed = 0
    var failed = 0

    mutating func check(_ name: String, _ body: () async throws -> Bool) async {
        do {
            guard try await body() else {
                failed += 1
                print("FAIL \(name): unexpected result")
                return
            }
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
    }

    static func main() async {
        var probe = Self()
        await probe.run()
        print("\(probe.passed) passed, \(probe.failed) failed")
        exit(probe.failed == 0 ? 0 : 1)
    }

    static func bigintMatches(driver: any PluginDatabaseDriver) async throws -> Bool {
        let result = try await driver.executeUserQuery(
            query: "SELECT $1::bigint AS imported_integer", rowCap: nil,
            parameters: [.text("2147483648")]
        )
        return result.rows == [[.text("2147483648")]]
    }

    mutating func checkSession(driver: any PluginDatabaseDriver, mode: String?) async {
        await check("session facts through protocol witness") {
            let result = try await driver.execute(query: "SELECT current_setting('database_mode')")
            let mode = result.rows.first?.first?.asText
            print("KingbaseES mode=\(mode ?? "unknown"), version=\(driver.serverVersion ?? "unknown")")
            guard let facts = driver.sessionLexicalState else { return false }
            let oracleFeatures = KingbaseESCompatibilityMode.lexicalFeaturesItDecides
            return facts.determined.isSuperset(of: oracleFeatures)
                && facts.enabled.intersection(oracleFeatures) == (mode == "oracle" ? oracleFeatures : [])
        }
        await check("mode probe reads pg or oracle") {
            let setting = try await driver.execute(query: KingbaseESCompatibilityMode.probeQuery).rows.first?.first?.asText
            let expected: KingbaseESCompatibilityMode? = switch mode {
            case "pg": .postgreSQL
            case "oracle": .oracle
            default: nil
            }
            return try KingbaseESCompatibilityMode(setting: setting) == expected
        }
        await check("mode-aware grammar splits and executes quoted semicolons") {
            guard let facts = driver.sessionLexicalState else { return false }
            let readings = SQLLexicalReadings.resolve(
                databaseTypeId: "KingbaseES", declared: nil,
                session: SQLSessionLexicalFacts(
                    determined: SQLLexicalGrammar(rawValue: facts.determined.rawValue),
                    enabled: SQLLexicalGrammar(rawValue: facts.enabled.rawValue)
                )
            )
            let sql = mode == "oracle"
                ? "SELECT q'[a;b]' AS value; SELECT $tag$c;d$tag$ AS value;"
                : "SELECT $tag$a;b$tag$ AS value; SELECT $tag$c;d$tag$ AS value;"
            let statements = SQLStatementScanner.executableStatements(in: sql, grammar: readings.execution)
            guard statements.count == 2 else { return false }
            for (index, statement) in statements.enumerated() {
                let result = try await driver.execute(query: statement.sql)
                guard result.rows.first?.first == .text(index == 0 ? "a;b" : "c;d") else { return false }
            }
            return true
        }
    }

    // Each column kind and the DESC index here lost its catalog spelling once Oracle mode read `''` as NULL.
    mutating func checkKeyedTable(driver: any PluginDatabaseDriver, schema: String) async throws {
        _ = try await driver.execute(query: "CREATE TABLE \(schema).keyed (id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, s serial, n integer NOT NULL DEFAULT 7, title text, g integer GENERATED ALWAYS AS (n * 2) STORED)")
        _ = try await driver.execute(query: "CREATE INDEX keyed_title_desc ON \(schema).keyed (title DESC NULLS LAST)")
        _ = try await driver.execute(query: "INSERT INTO \(schema).keyed (title) VALUES ('a')")
        await check("index keeps its DESC spelling") {
            let indexes = try await driver.fetchIndexes(table: "keyed", schema: schema)
            let spelling = indexes.first { $0.name == "keyed_title_desc" }?.ddlMethodAndKeys
            print("Index spelling: \(spelling ?? "nil")")
            return spelling?.contains("(title DESC NULLS LAST)") == true
        }
        await check("identity, default and generation expression") {
            let columns = try await driver.fetchColumns(table: "keyed", schema: schema)
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
            return byName["id"]?.isIdentity == true && byName["n"]?.defaultValue == "7"
                && byName["g"]?.isGenerated == true && byName["g"]?.generationExpression == "(n * 2)"
        }
        await check("table DDL keeps column defaults") {
            let ddl = try await driver.fetchTableDDL(table: "keyed", schema: schema)
            return ddl.contains("DEFAULT 7") && ddl.contains("DEFAULT nextval(")
                && ddl.contains("GENERATED ALWAYS AS IDENTITY")
        }
        await check("column reorder rebuild runs and keeps keys and defaults") {
            guard let plan = try await driver.generateColumnReorderPlan(
                table: "keyed", schema: schema, columns: [], desiredOrder: ["title", "id", "s", "n", "g"]
            ) else { return false }
            _ = try await driver.execute(query: "SAVEPOINT reorder")
            do {
                for statement in plan.statements { _ = try await driver.execute(query: statement) }
                _ = try await driver.execute(query: "INSERT INTO \(schema).keyed (title) VALUES ('b')")
                let row = try await driver.execute(query: "SELECT id, s, n, g FROM \(schema).keyed WHERE title = 'b'")
                _ = try await driver.execute(query: "ROLLBACK TO SAVEPOINT reorder")
                return row.rows == [[.text("2"), .text("2"), .text("7"), .text("14")]]
            } catch {
                _ = try await driver.execute(query: "ROLLBACK TO SAVEPOINT reorder")
                throw error
            }
        }
    }

    mutating func run() async {
        let env = ProcessInfo.processInfo.environment
        let database = env["TP_KINGBASE_DATABASE"] ?? "test"
        let config = DriverConnectionConfig(
            host: env["TP_KINGBASE_HOST"] ?? "127.0.0.1",
            port: Int(env["TP_KINGBASE_PORT"] ?? "55432") ?? 55_432,
            username: env["TP_KINGBASE_USER"] ?? "system",
            password: env["TP_KINGBASE_PASSWORD"] ?? "", database: database
        )
        let driver: any PluginDatabaseDriver = KingbaseESPlugin().createDriver(config: config)
        defer { driver.disconnect() }
        await check("no session lexical state before connect") { driver.sessionLexicalState == nil }
        do { try await driver.connect() } catch {
            failed += 1
            print("FAIL connect: \(error)")
            return
        }
        let mode = try? await driver.execute(query: "SELECT current_setting('database_mode')").rows.first?.first?.asText
        await checkSession(driver: driver, mode: mode)
        await check("database catalog") { try await driver.fetchDatabases().contains(database) }
        let schema = "tp_probe_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let table = "\(schema).sample"
        do {
            try await driver.beginTransaction()
            _ = try await driver.execute(query: "CREATE SCHEMA \(schema)")
            _ = try await driver.execute(query: "CREATE TYPE \(schema).mood AS ENUM ('ok', 'bad')")
            _ = try await driver.execute(query: "CREATE TABLE \(schema).parent (id integer PRIMARY KEY)")
            _ = try await driver.execute(query: "CREATE TABLE \(table) (id integer PRIMARY KEY, parent_id integer REFERENCES \(schema).parent(id), flag boolean, payload bytea, title text COLLATE \"C\", amount numeric(12,2), missing text, doubled integer GENERATED ALWAYS AS (id * 2) STORED)")
            _ = try await driver.execute(query: "CREATE INDEX sample_title_idx ON \(table)(title)")
            _ = try await driver.execute(query: "CREATE FUNCTION \(schema).answer() RETURNS integer LANGUAGE SQL AS 'SELECT 42'")
            await check("schema catalog") { try await driver.fetchSchemas().contains(schema) }
            await check("table catalog") { try await driver.fetchTables(schema: schema).contains { $0.name == "sample" } }
            await check("column catalog and generated column") {
                let columns = try await driver.fetchColumns(table: "sample", schema: schema)
                return columns.count == 8 && columns.contains { $0.name == "doubled" && $0.isGenerated }
            }
            await check("index catalog") { try await driver.fetchIndexes(table: "sample", schema: schema).count >= 2 }
            try await checkKeyedTable(driver: driver, schema: schema)
            await check("foreign key catalog") { try await driver.fetchForeignKeys(table: "sample", schema: schema).count == 1 }
            await check("routine catalog and DDL") {
                let routines = try await driver.fetchRoutines(schema: schema)
                guard let routine = routines.first(where: { $0.name == "answer" }) else { return false }
                return try await driver.fetchRoutineDDL(routine).contains("42")
            }
            await check("type catalog and definition") {
                let types = try await driver.fetchUserDefinedTypes(schema: schema)
                guard let mood = types.first(where: { $0.name == "mood" }) else { return false }
                return try await driver.fetchUserDefinedType(mood).name == "mood"
            }
            await check("table DDL") {
                let ddl = try await driver.fetchTableDDL(table: "sample", schema: schema)
                print("Table DDL: \(ddl)")
                guard ddl.contains("CREATE TABLE"), ddl.contains("GENERATED ALWAYS"),
                      ddl.contains("COLLATE ") else { return false }
                let replay = ddl.replacingOccurrences(of: "\"sample\"", with: "\"replay\"")
                _ = try await driver.execute(query: "SAVEPOINT ddl_replay")
                do {
                    _ = try await driver.execute(query: replay)
                    let columns = try await driver.fetchColumns(table: "replay", schema: schema)
                    _ = try await driver.execute(query: "ROLLBACK TO SAVEPOINT ddl_replay")
                    return columns.count == 8 && columns.contains { $0.name == "doubled" && $0.isGenerated }
                } catch {
                    _ = try await driver.execute(query: "ROLLBACK TO SAVEPOINT ddl_replay")
                    throw error
                }
            }
            await check("parameterized insert and values") {
                _ = try await driver.executeUserQuery(
                    query: "INSERT INTO \(table)(id,flag,payload,title,amount,missing) VALUES (1,$1::boolean,$2::bytea,$3,$4::numeric,$5)",
                    rowCap: nil, parameters: [.text("true"), .bytes(Data([0, 1, 255])), .text("Việt Nam 日本"), .text("1234.50"), .null]
                )
                let result = try await driver.execute(query: "SELECT flag,payload,title,amount,missing,doubled FROM \(table)")
                return result.rows.first == [.text("true"), .bytes(Data([0, 1, 255])), .text("Việt Nam 日本"), .text("1234.50"), .null, .text("2")]
            }
            await check("parameterized bigint beyond Int32 range") {
                try await Self.bigintMatches(driver: driver)
            }
            await check("parameterized update and empty bytea") {
                _ = try await driver.executeUserQuery(query: "UPDATE \(table) SET payload=$1::bytea WHERE id=1", rowCap: nil, parameters: [.bytes(Data())])
                let result = try await driver.execute(query: "SELECT payload, octet_length(payload) FROM \(table)")
                return mode == "oracle" ? result.rows.first == [.null, .null]
                    : result.rows.first == [.bytes(Data()), .text("0")]
            }
            await check("savepoint rollback") {
                _ = try await driver.execute(query: "SAVEPOINT probe_save")
                _ = try await driver.execute(query: "DELETE FROM \(table)")
                _ = try await driver.execute(query: "ROLLBACK TO SAVEPOINT probe_save")
                return try await driver.execute(query: "SELECT count(*) FROM \(table)").rows.first?.first == .text("1")
            }
            await check("delete") {
                _ = try await driver.execute(query: "DELETE FROM \(table)")
                return try await driver.execute(query: "SELECT count(*) FROM \(table)").rows.first?.first == .text("0")
            }
        } catch {
            failed += 1
            print("FAIL fixture: \(error)")
        }
        await check("rollback removes all test objects") {
            try await driver.rollbackTransaction()
            return try await !driver.fetchSchemas().contains(schema)
        }
        await check("reconnect") {
            driver.disconnect()
            guard driver.sessionLexicalState == nil else { return false }
            try await driver.connect()
            try await driver.ping()
            return true
        }
        await check("cancellation after server reports active query") {
            let observer = KingbaseESPlugin().createDriver(config: config)
            try await observer.connect()
            defer { observer.disconnect() }
            guard let pid = try await driver.execute(query: "SELECT pg_backend_pid()").rows.first?.first?.asText
            else { return false }
            let query = Task { try await driver.execute(query: "SELECT pg_sleep(30)") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var active = false
            while ContinuousClock.now < deadline {
                let result = try await observer.execute(query: "SELECT state, query FROM pg_stat_activity WHERE pid=\(pid)")
                if let row = result.rows.first, row[0].asText == "active", row[1].asText?.contains("pg_sleep") == true {
                    active = true
                    break
                }
                await Task.yield()
            }
            try driver.cancelQuery()
            do { _ = try await query.value; return false } catch {
                print("Cancellation active=\(active), error=\(error), SQLSTATE=\((error as? any PluginDriverError)?.pluginSqlState ?? "none")")
                guard active, error is CancellationError
                    || (error as? any PluginDriverError)?.pluginSqlState == "57014" else { return false }
                try await driver.ping()
                return true
            }
        }
    }
}
