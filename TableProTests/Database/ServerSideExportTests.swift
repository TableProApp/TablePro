//
//  ServerSideExportTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Server-side export")
struct ServerSideExportTests {

    private func statement(
        _ type: DatabaseType,
        destination: ServerSideExport.Destination,
        table: String = "orders",
        schema: String? = nil,
        format: ServerSideExport.Format = .csv
    ) -> String? {
        ServerSideExport.statement(
            for: ServerSideExport.Request(
                table: table, schema: schema, destination: destination, format: format),
            databaseType: type,
            quoteIdentifier: { "\"\($0)\"" },
            escapeLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        )
    }

    /// These three are the engines with no client-side dump. Everything else has one and belongs in
    /// `NativeDumpRegistry`, so the two lists must not overlap.
    @Test("Only the engines that unload server-side are offered")
    func supportedEngines() {
        #expect(ServerSideExport.supports(.oracle))
        #expect(ServerSideExport.supports(.bigQuery))
        #expect(ServerSideExport.supports(ServerSideExport.snowflake))

        for type in [DatabaseType.postgresql, .mysql, .sqlite, .mongodb, .mssql] {
            #expect(!ServerSideExport.supports(type), "\(type.rawValue) has a client-side dump")
        }
    }

    @Test("An engine with a client-side dump is never in both registries")
    func noOverlapWithNativeDump() {
        for type in [DatabaseType.oracle, .bigQuery, ServerSideExport.snowflake] {
            #expect(!NativeDumpRegistry.supports(type), "\(type.rawValue) is in both")
        }
    }

    @Test("Each engine offers its own destination kind and formats")
    func destinationsAndFormats() {
        #expect(ServerSideExport.destinationKinds(for: .oracle) == [.oracleDirectory(name: "")])
        #expect(ServerSideExport.destinationKinds(for: .bigQuery) == [.googleCloudStorage(uri: "")])
        #expect(ServerSideExport.destinationKinds(for: ServerSideExport.snowflake)
            == [.snowflakeStage(name: "")])
        #expect(ServerSideExport.destinationKinds(for: .postgresql).isEmpty)

        #expect(ServerSideExport.supportedFormats(for: .oracle) == [.csv])
        #expect(ServerSideExport.supportedFormats(for: .bigQuery).contains(.parquet))
    }

    // MARK: - Oracle

    @Test("Oracle starts a Data Pump job against the named directory object")
    func oracleUsesDataPump() throws {
        let sql = try #require(statement(.oracle, destination: .oracleDirectory(name: "data_pump_dir")))
        #expect(sql.contains("DBMS_DATAPUMP.OPEN"))
        #expect(sql.contains("DBMS_DATAPUMP.START_JOB"))
        #expect(sql.contains("'orders.dmp', 'DATA_PUMP_DIR'"))
        #expect(sql.contains("'orders.log', 'DATA_PUMP_DIR'"))
        #expect(sql.contains("'IN (''ORDERS'')'"))
    }

    /// Data Pump filters by schema separately from table, so an unqualified request has to name the
    /// session's own schema or it exports from whichever one the job happens to run as.
    @Test("Oracle falls back to the session user when no schema is given")
    func oracleSchemaFallback() throws {
        let unqualified = try #require(statement(.oracle, destination: .oracleDirectory(name: "d")))
        #expect(unqualified.contains("USER"))

        let qualified = try #require(
            statement(.oracle, destination: .oracleDirectory(name: "d"), schema: "sales"))
        #expect(qualified.contains("'IN (''SALES'')'"))
    }

    @Test("Oracle refuses an empty directory rather than naming one the server does not have")
    func oracleRequiresDirectory() {
        #expect(statement(.oracle, destination: .oracleDirectory(name: "")) == nil)
    }

    // MARK: - Snowflake

    @Test("Snowflake copies into the stage and takes the format's own options")
    func snowflakeCopiesIntoStage() throws {
        let sql = try #require(statement(
            ServerSideExport.snowflake, destination: .snowflakeStage(name: "@my_stage")))
        #expect(sql.hasPrefix("COPY INTO '@my_stage/orders'"))
        #expect(sql.contains("FROM \"orders\""))
        #expect(sql.contains("TYPE = CSV"))
        #expect(sql.contains("OVERWRITE = FALSE"))
    }

    /// A stage is written `@name`, and a user who types it without the sigil means the same stage.
    @Test("A stage name without its @ still resolves")
    func snowflakeAddsTheSigil() throws {
        let sql = try #require(statement(
            ServerSideExport.snowflake, destination: .snowflakeStage(name: "my_stage")))
        #expect(sql.contains("'@my_stage/orders'"))
    }

    @Test("Snowflake qualifies the table when a schema is given")
    func snowflakeQualifies() throws {
        let sql = try #require(statement(
            ServerSideExport.snowflake,
            destination: .snowflakeStage(name: "s"),
            schema: "sales"))
        #expect(sql.contains("FROM \"sales\".\"orders\""))
    }

    @Test("Snowflake picks the file format from the chosen format")
    func snowflakeFormats() throws {
        let parquet = try #require(statement(
            ServerSideExport.snowflake, destination: .snowflakeStage(name: "s"), format: .parquet))
        #expect(parquet.contains("TYPE = PARQUET"))
    }

    // MARK: - BigQuery

    /// `EXPORT DATA` shards its output, so a URI with no wildcard is rejected by BigQuery with an
    /// error that does not say why. The suffix is added rather than passing it through.
    @Test("BigQuery adds a shard wildcard when the URI has none")
    func bigQueryAddsWildcard() throws {
        let sql = try #require(statement(
            .bigQuery, destination: .googleCloudStorage(uri: "gs://bucket/exports/")))
        #expect(sql.contains("gs://bucket/exports/orders-*.csv"))
        #expect(sql.contains("format = 'CSV'"))
    }

    @Test("A URI already carrying a wildcard is left alone")
    func bigQueryKeepsExistingWildcard() throws {
        let sql = try #require(statement(
            .bigQuery, destination: .googleCloudStorage(uri: "gs://bucket/part-*.csv")))
        #expect(sql.contains("uri = 'gs://bucket/part-*.csv'"))
    }

    @Test("A URI missing its scheme is refused")
    func bigQueryRequiresScheme() {
        #expect(statement(.bigQuery, destination: .googleCloudStorage(uri: "bucket/exports")) == nil)
        #expect(statement(.bigQuery, destination: .googleCloudStorage(uri: "")) == nil)
    }

    /// BigQuery spells newline-delimited JSON differently from everyone else, and plain `JSON` is
    /// not an accepted value.
    @Test("BigQuery spells JSON as NEWLINE_DELIMITED_JSON")
    func bigQueryJSONSpelling() throws {
        let sql = try #require(statement(
            .bigQuery, destination: .googleCloudStorage(uri: "gs://b/x/"), format: .json))
        #expect(sql.contains("format = 'NEWLINE_DELIMITED_JSON'"))
    }

    // MARK: - File naming

    /// A table name can hold characters that are legal in an identifier and not in a file name on
    /// whatever machine the server runs on.
    @Test("A file stem drops everything a server file name cannot carry")
    func fileStemIsSanitized() {
        #expect(ServerSideExport.sanitizedFileStem("orders") == "orders")
        #expect(ServerSideExport.sanitizedFileStem("sales.orders") == "sales_orders")
        #expect(ServerSideExport.sanitizedFileStem("a/b c") == "a_b_c")
        #expect(ServerSideExport.sanitizedFileStem("") == "export")
        #expect(ServerSideExport.sanitizedFileStem("...") == "___")
    }
}

@Suite("SQL Server dump")
struct SQLServerDumpTests {

    private func command(kind: NativeDumpKind, username: String = "sa") throws -> NativeDumpCommand {
        var sslConfig = SSLConfiguration()
        sslConfig.mode = .disabled
        let connection = DatabaseConnection(
            name: "Test", host: "db.example.com", port: 1_433, database: "sales",
            username: username, type: .mssql,
            sshConfig: SSHConfiguration(), sslConfig: sslConfig
        )
        let descriptor = try #require(NativeDumpRegistry.descriptor(for: .mssql))
        return try NativeDumpService.buildCommand(
            kind: kind,
            descriptor: descriptor,
            executable: URL(fileURLWithPath: "/usr/local/bin/sqlpackage"),
            effective: connection,
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/sales.bacpac"),
            password: "s3cret"
        )
    }

    @Test("SQL Server exports and imports a bacpac through sqlpackage")
    func bacpacActions() throws {
        let backup = try command(kind: .backup)
        #expect(backup.arguments.contains("/Action:Export"))
        #expect(backup.arguments.contains("/TargetFile:/tmp/sales.bacpac"))

        let restore = try command(kind: .restore)
        #expect(restore.arguments.contains("/Action:Import"))
        #expect(restore.arguments.contains("/SourceFile:/tmp/sales.bacpac"))
    }

    @Test("The archive is a bacpac and the tool writes it itself")
    func archiveShape() throws {
        let descriptor = try #require(NativeDumpRegistry.descriptor(for: .mssql))
        #expect(descriptor.archiveFormat.fileExtension == "bacpac")
        #expect(descriptor.backupDelivery == .toolWritesFile)
        #expect(try command(kind: .backup).redirectedFileURL == nil)
    }

    /// An empty username means Windows or Entra authentication, which carries no password at all.
    @Test("No username asks for integrated security instead of a blank password")
    func integratedSecurity() throws {
        let anonymous = try command(kind: .backup, username: "")
        let connectionString = try #require(
            anonymous.arguments.first { $0.hasPrefix("/SourceConnectionString:") })
        #expect(connectionString.contains("Integrated Security=true"))
        #expect(!connectionString.contains("Password="))
    }

    /// Recorded rather than asserted away: `sqlpackage` takes no password flag and no password
    /// environment variable, so the connection string is its only channel and the password is
    /// visible in `ps`. Every other engine keeps it out of `argv`.
    @Test("SQL Server is the one engine whose password reaches the argument list")
    func passwordIsInArgvForSQLServerOnly() throws {
        let backup = try command(kind: .backup)
        #expect(backup.arguments.contains { $0.contains("s3cret") })
        #expect(backup.environment["SQLCMDPASSWORD"] == nil)
    }
}
