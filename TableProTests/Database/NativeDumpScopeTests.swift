//
//  NativeDumpScopeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Native dump object scope")
struct NativeDumpScopeTests {

    private func connection(type: DatabaseType, database: String = "sales") -> DatabaseConnection {
        DatabaseConnection(
            name: "Test",
            host: "db.example.com",
            port: 5_432,
            database: database,
            username: "alice",
            type: type,
            sshConfig: SSHConfiguration(),
            sslConfig: SSLConfiguration()
        )
    }

    private func arguments(
        _ type: DatabaseType,
        scope: NativeDumpScope,
        kind: NativeDumpKind = .backup,
        database: String = "sales",
        localFilePath: String? = nil
    ) throws -> [String] {
        let tool = try #require(NativeDumpRegistry.descriptor(for: type)?.commandLineTool)
        let request = NativeDumpDescriptor.Request(
            connection: connection(type: type, database: database),
            database: database,
            fileURL: URL(fileURLWithPath: "/tmp/out.bin"),
            password: nil,
            scope: scope,
            localFilePath: localFilePath
        )
        return tool.arguments(for: kind, request: request)
    }

    // MARK: - PostgreSQL

    /// Measured with pg_dump 17.11: `-t` is a psql `\d` pattern, not a name. `-t 'app.Orders'`
    /// exits with "no matching tables were found" because the pattern folds to lower case, and
    /// `-t 'order.item'` splits on the dot. Only the fully quoted form matches exactly one table.
    @Test("Every picked PostgreSQL table is quoted schema and name apart")
    func postgresQuotesEveryPattern() {
        #expect(
            NativeDumpArgumentQuoting.postgresTablePattern(
                NativeDumpObject(name: "Orders", schema: "app")
            ) == "\"app\".\"Orders\""
        )
        #expect(
            NativeDumpArgumentQuoting.postgresTablePattern(
                NativeDumpObject(name: "order.item", schema: "app")
            ) == "\"app\".\"order.item\""
        )
        #expect(
            NativeDumpArgumentQuoting.postgresTablePattern(
                NativeDumpObject(name: "t[1]", schema: "app")
            ) == "\"app\".\"t[1]\""
        )
        #expect(
            NativeDumpArgumentQuoting.postgresTablePattern(
                NativeDumpObject(name: "star*", schema: "app")
            ) == "\"app\".\"star*\""
        )
        #expect(
            NativeDumpArgumentQuoting.postgresTablePattern(
                NativeDumpObject(name: "we\"ird", schema: "app")
            ) == "\"app\".\"we\"\"ird\""
        )
        #expect(
            NativeDumpArgumentQuoting.postgresTablePattern(
                NativeDumpObject(name: "plain")
            ) == "\"plain\""
        )
    }

    @Test("A narrowed PostgreSQL dump passes one -t per table and nothing else changes")
    func postgresNarrowedArguments() throws {
        let whole = try arguments(.postgresql, scope: .wholeDatabase)
        #expect(!whole.contains("-t"))

        let narrowed = try arguments(
            .postgresql,
            scope: .objects([
                NativeDumpObject(name: "orders", schema: "app"),
                NativeDumpObject(name: "Line Items", schema: "app")
            ])
        )
        #expect(narrowed.filter { $0 == "-t" }.count == 2)
        #expect(narrowed.contains("\"app\".\"orders\""))
        #expect(narrowed.contains("\"app\".\"Line Items\""))
        #expect(narrowed.contains("-Fc"))
    }

    @Test("A restore is never narrowed")
    func postgresRestoreIgnoresScope() throws {
        let restore = try arguments(
            .postgresql,
            scope: .objects([NativeDumpObject(name: "orders", schema: "app")]),
            kind: .restore
        )
        #expect(!restore.contains("-t"))
    }

    // MARK: - MySQL

    /// `mysqldump [options] database [tables]`, and the tool's own help says table names are
    /// literal unless `--wildcards` is passed, so nothing is escaped here.
    @Test("A narrowed MySQL dump lists its tables after the database")
    func mysqlNarrowedArguments() throws {
        let narrowed = try arguments(
            .mysql,
            scope: .objects([NativeDumpObject(name: "orders"), NativeDumpObject(name: "line_items")])
        )
        let databaseIndex = try #require(narrowed.firstIndex(of: "sales"))
        #expect(Array(narrowed[databaseIndex...]) == ["sales", "--", "orders", "line_items"])
        #expect(!narrowed.contains("--wildcards"))
    }

    /// `my_getopt` does not stop parsing options at the first positional argument. Measured with
    /// mysqldump 12.3.2: a table named `--no-data` passed bare was read as the option and the dump
    /// came back with zero rows at exit 0, which the result sheet reports as a success. `--` in
    /// front makes it a table name again.
    @Test("A hostile MySQL table name cannot become an option")
    func mysqlSeparatesItsTableList() throws {
        let narrowed = try arguments(
            .mysql,
            scope: .objects([
                NativeDumpObject(name: "orders"),
                NativeDumpObject(name: "--no-data")
            ])
        )
        let separator = try #require(narrowed.firstIndex(of: "--"))
        let hostile = try #require(narrowed.firstIndex(of: "--no-data"))
        #expect(separator < hostile, "every table name must sit after the end-of-options marker")
    }

    @Test("A whole-database MySQL dump passes no separator")
    func mysqlWholeDatabaseHasNoSeparator() throws {
        #expect(!(try arguments(.mysql, scope: .wholeDatabase)).contains("--"))
    }

    // MARK: - MongoDB

    @Test("A narrowed MongoDB dump names each collection instead of the database")
    func mongoNarrowedArguments() throws {
        let whole = try arguments(.mongodb, scope: .wholeDatabase)
        #expect(whole.contains("--db=sales"))

        let narrowed = try arguments(
            .mongodb,
            scope: .objects([NativeDumpObject(name: "orders"), NativeDumpObject(name: "carts")])
        )
        #expect(!narrowed.contains("--db=sales"))
        #expect(narrowed.contains("--nsInclude=sales.orders"))
        #expect(narrowed.contains("--nsInclude=sales.carts"))
    }

    // MARK: - SQLite

    /// Two layers, both measured with sqlite3 3.54.0. `.dump user_data` also dumps `userXdata`,
    /// because each name is a `LIKE` pattern over `sqlite_master.name`, so `\`, `%` and `_` are
    /// escaped first. The dot-command tokenizer then reads `\` and `"` inside a double-quoted
    /// token, so both are escaped again on top: `"back\\\\slash"` is what matched `back\slash`.
    @Test("SQLite escapes for the LIKE pattern and then for the tokenizer")
    func sqliteEscapesBothLayers() {
        #expect(NativeDumpArgumentQuoting.sqliteDumpToken("plain") == "\"plain\"")
        #expect(NativeDumpArgumentQuoting.sqliteDumpToken("user_data") == "\"user\\\\_data\"")
        #expect(NativeDumpArgumentQuoting.sqliteDumpToken("user%data") == "\"user\\\\%data\"")
        #expect(NativeDumpArgumentQuoting.sqliteDumpToken("back\\slash") == "\"back\\\\\\\\slash\"")
        #expect(NativeDumpArgumentQuoting.sqliteDumpToken("we\"ird") == "\"we\\\"ird\"")
    }

    /// One process argument, not one per name.
    ///
    /// `sqlite3` parses its own command line, so a table named `-cmd` and one named
    /// `.shell touch /tmp/x` handed over as separate arguments run an arbitrary shell command; both
    /// characters are legal in a quoted SQLite identifier and `BackupScopeLoader.expandDependents`
    /// pulls index and trigger names in automatically. Measured: as separate arguments the payload
    /// executed, and inside one quoted `.dump` command it is inert.
    ///
    /// The separate-argument shape did not filter either. Measured: `sqlite3 db .dump t1` prints a
    /// parse error and dumps the whole database.
    @Test("A narrowed SQLite dump is one .dump command, so a hostile name cannot become an option")
    func sqliteNarrowedIsASingleCommand() throws {
        let narrowed = try arguments(
            .sqlite,
            scope: .objects([
                NativeDumpObject(name: "user_data"),
                NativeDumpObject(name: "idx_user_data_b")
            ]),
            localFilePath: "/tmp/app.sqlite"
        )
        #expect(narrowed == ["/tmp/app.sqlite", ".dump \"user\\\\_data\" \"idx\\\\_user\\\\_data\\\\_b\""])
        #expect(narrowed.count == 2, "every name must stay inside the one command argument")
    }

    @Test("A hostile SQLite object name cannot reach argv as an option")
    func sqliteHostileNamesStayQuoted() throws {
        let narrowed = try arguments(
            .sqlite,
            scope: .objects([
                NativeDumpObject(name: "-cmd"),
                NativeDumpObject(name: ".shell touch /tmp/pwned")
            ]),
            localFilePath: "/tmp/app.sqlite"
        )
        #expect(narrowed.count == 2)
        #expect(!narrowed.contains { $0.hasPrefix("-") })
        #expect(narrowed[1] == ".dump \"-cmd\" \".shell touch /tmp/pwned\"")
    }

    @Test("A whole-database SQLite dump passes a bare .dump")
    func sqliteWholeDatabaseArguments() throws {
        let whole = try arguments(.sqlite, scope: .wholeDatabase, localFilePath: "/tmp/app.sqlite")
        #expect(whole == ["/tmp/app.sqlite", ".dump"])
    }

    // MARK: - SQL Server

    @Test("A narrowed SQL Server export narrows only the table data")
    func sqlServerNarrowedArguments() throws {
        let narrowed = try arguments(
            .mssql,
            scope: .objects([NativeDumpObject(name: "Orders", schema: "dbo")])
        )
        #expect(narrowed.contains("/p:TableData=dbo.Orders"))
    }

    // MARK: - Capability

    /// The sheet reads this to decide whether to offer a picker at all. DuckDB has no filter, and
    /// widening a selection back to the whole database without saying so is the defect the type
    /// exists to prevent.
    @Test("Only the engines with a filter allow narrowing")
    func narrowingCapability() throws {
        for type in [DatabaseType.postgresql, .mysql, .mongodb, .sqlite, .mssql] {
            let scope = try #require(NativeDumpRegistry.descriptor(for: type)?.objectScope)
            #expect(scope.allowsNarrowing, "\(type.rawValue) should allow narrowing")
        }
        let duckdb = try #require(NativeDumpRegistry.descriptor(for: .duckdb)?.objectScope)
        #expect(!duckdb.allowsNarrowing)
        #expect(duckdb.narrowedCaveat?.isEmpty == false)
    }

    @Test("MongoDB counts collections and everything else counts tables")
    func unitNouns() throws {
        let mongo = try #require(NativeDumpRegistry.descriptor(for: .mongodb)?.objectScope)
        #expect(mongo.unitNoun == "collections")
        #expect(mongo.singularUnitNoun == "collection")

        let postgres = try #require(NativeDumpRegistry.descriptor(for: .postgresql)?.objectScope)
        #expect(postgres.unitNoun == "tables")
    }

    /// A caller that filters a selection down to nothing gets the whole database, not an empty
    /// file that looks like a successful backup.
    @Test("An empty object list reads as the whole database")
    func emptyScopeIsWholeDatabase() {
        #expect(NativeDumpScope.objects([]).isWholeDatabase)
        #expect(NativeDumpScope.wholeDatabase.isWholeDatabase)
        #expect(!NativeDumpScope.objects([NativeDumpObject(name: "t")]).isWholeDatabase)
    }
}

@Suite("DuckDB in-engine dump statements")
struct DuckDBDumpStatementTests {

    private func connection() -> DatabaseConnection {
        var connection = DatabaseConnection(
            name: "Local",
            host: "",
            port: 0,
            database: "",
            username: "",
            type: .duckdb,
            sshConfig: SSHConfiguration(),
            sslConfig: SSLConfiguration()
        )
        connection.additionalFields["duckdbFilePath"] = "/tmp/my-weird.name.db"
        return connection
    }

    private func request(
        fileURL: URL,
        catalog: String?
    ) -> NativeDumpDescriptor.Request {
        NativeDumpDescriptor.Request(
            connection: connection(),
            database: "my-weird",
            fileURL: fileURL,
            password: nil,
            currentCatalog: catalog,
            localFilePath: "/tmp/my-weird.name.db"
        )
    }

    /// Measured against the vendored libduckdb v1.5.2. The source catalog has to come from
    /// `current_database()`: a file `my-weird.name.db` attaches as `my-weird`, and
    /// `COPY FROM DATABASE main` fails with `Catalog "main" does not exist`.
    @Test("A single-file backup attaches, copies from the live catalog, and detaches")
    func duckDBFileBackup() throws {
        let engine = try #require(
            NativeDumpRegistry.descriptor(for: .duckdb, formatId: "duckdb")?.engineStatements
        )
        let statements = engine.statements(
            for: .backup,
            request: request(fileURL: URL(fileURLWithPath: "/tmp/out.duckdb"), catalog: "my-weird"),
            alias: "bak1"
        )
        #expect(statements == [
            "ATTACH '/tmp/out.duckdb' AS \"bak1\"",
            "COPY FROM DATABASE \"my-weird\" TO \"bak1\"",
            "DETACH \"bak1\""
        ])
    }

    @Test("A single-file restore reads the backup read-only and copies into the live catalog")
    func duckDBFileRestore() throws {
        let engine = try #require(
            NativeDumpRegistry.descriptor(for: .duckdb, formatId: "duckdb")?.engineStatements
        )
        let statements = engine.statements(
            for: .restore,
            request: request(fileURL: URL(fileURLWithPath: "/tmp/out.duckdb"), catalog: "live"),
            alias: "bak1"
        )
        #expect(statements == [
            "ATTACH '/tmp/out.duckdb' AS \"bak1\" (READ_ONLY)",
            "COPY FROM DATABASE \"bak1\" TO \"live\"",
            "DETACH \"bak1\""
        ])
    }

    /// Without a catalog there is no correct statement to send, and guessing one writes an empty
    /// backup or copies out of the wrong database. The service turns an empty list into an error.
    @Test("No catalog produces no statements")
    func duckDBWithoutCatalog() throws {
        let engine = try #require(
            NativeDumpRegistry.descriptor(for: .duckdb, formatId: "duckdb")?.engineStatements
        )
        let statements = engine.statements(
            for: .backup,
            request: request(fileURL: URL(fileURLWithPath: "/tmp/out.duckdb"), catalog: nil),
            alias: "bak1"
        )
        #expect(statements.isEmpty)
    }

    @Test("A path with a quote in it is escaped into the literal")
    func duckDBEscapesTheDestination() throws {
        let engine = try #require(
            NativeDumpRegistry.descriptor(for: .duckdb, formatId: "duckdb")?.engineStatements
        )
        let statements = engine.statements(
            for: .backup,
            request: request(fileURL: URL(fileURLWithPath: "/tmp/o'ut.duckdb"), catalog: "live"),
            alias: "bak1"
        )
        #expect(statements.first == "ATTACH '/tmp/o''ut.duckdb' AS \"bak1\"")
    }

    @Test("The Parquet format exports and imports a folder and needs no catalog")
    func duckDBParquetStatements() throws {
        let engine = try #require(
            NativeDumpRegistry.descriptor(for: .duckdb, formatId: "parquet")?.engineStatements
        )
        let backup = engine.statements(
            for: .backup,
            request: request(fileURL: URL(fileURLWithPath: "/tmp/dump"), catalog: nil),
            alias: "unused"
        )
        #expect(backup == ["EXPORT DATABASE '/tmp/dump' (FORMAT PARQUET)"])

        let restore = engine.statements(
            for: .restore,
            request: request(fileURL: URL(fileURLWithPath: "/tmp/dump"), catalog: nil),
            alias: "unused"
        )
        #expect(restore == ["IMPORT DATABASE '/tmp/dump'"])
    }

    /// Measured: `EXPORT DATABASE` merges into a folder that already holds one, leaving the
    /// previous run's data files behind, so the folder format is a directory destination.
    @Test("DuckDB offers a single file and a Parquet folder, in that order")
    func duckDBFormats() {
        let formats = NativeDumpRegistry.formats(for: .duckdb)
        #expect(formats.map(\.id) == ["duckdb", "parquet"])
        #expect(formats[0].fileExtension == "duckdb")
        #expect(!formats[0].producesDirectory)
        #expect(formats[1].producesDirectory)
        #expect(formats[1].fileExtension.isEmpty)
    }

    /// DuckDB reaches more than one catalog at once through `ATTACH`, so a run has to copy the
    /// catalog that was ticked rather than whichever one the session is parked on.
    @Test("The picked database wins over the session's own catalog when the engine lists it")
    func catalogResolution() {
        #expect(
            NativeDumpService.catalogName(
                picked: "warehouse", reported: ["memory", "warehouse"], current: "memory"
            ) == "warehouse"
        )
    }

    /// The single-container fallback names a database after the file, and a file
    /// `my-weird.name.db` attaches as the catalog `my-weird`, so the engine's own answer is the
    /// only one that matches.
    @Test("A name the engine does not list falls back to the session's catalog")
    func catalogFallback() {
        #expect(
            NativeDumpService.catalogName(
                picked: "my-weird.name.db", reported: [], current: "my-weird"
            ) == "my-weird"
        )
        #expect(
            NativeDumpService.catalogName(picked: "sales", reported: [], current: nil) == "sales"
        )
        #expect(NativeDumpService.catalogName(picked: "", reported: [], current: nil) == nil)
    }

    @Test("Every other engine offers exactly one format")
    func singleFormatEngines() {
        for type in [DatabaseType.postgresql, .mysql, .mongodb, .sqlite, .mssql] {
            #expect(NativeDumpRegistry.formats(for: type).count == 1, "\(type.rawValue)")
        }
    }
}
