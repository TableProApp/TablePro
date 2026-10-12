//
//  SQLServerDumpTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct SQLServerDumpTests {
    private func command(kind: NativeDumpKind, username: String = "sa") throws -> NativeDumpCommand {
        var sslConfig = SSLConfiguration()
        sslConfig.mode = .disabled
        let connection = DatabaseConnection(
            name: "Test", host: "db.example.com", port: 1_433, database: "sales",
            username: username, type: .mssql,
            sshConfig: SSHConfiguration(), sslConfig: sslConfig
        )
        let tool = try #require(NativeDumpRegistry.descriptor(for: .mssql)?.commandLineTool)
        return try NativeDumpService.buildCommand(
            kind: kind,
            tool: tool,
            resolved: NativeDumpResolvedTool(name: "sqlpackage", path: "/usr/local/bin/sqlpackage"),
            request: NativeDumpDescriptor.Request(
                connection: connection,
                database: "sales",
                fileURL: URL(fileURLWithPath: "/tmp/sales.bacpac"),
                password: "s3cret"
            )
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
        #expect(descriptor.commandLineTool?.backupDelivery == .toolWritesFile)
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
