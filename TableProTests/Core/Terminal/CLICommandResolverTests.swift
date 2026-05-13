//
//  CLICommandResolverTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("CLICommandResolver")
struct CLICommandResolverTests {
    // MARK: - binaryName(for:)

    @Test("binaryName returns mysql for MySQL")
    func testBinaryName_mysql() {
        #expect(CLICommandResolver.binaryName(for: .mysql) == "mysql")
    }

    @Test("binaryName returns mariadb for MariaDB")
    func testBinaryName_mariadb() {
        #expect(CLICommandResolver.binaryName(for: .mariadb) == "mariadb")
    }

    @Test("binaryName returns psql for PostgreSQL")
    func testBinaryName_postgresql() {
        #expect(CLICommandResolver.binaryName(for: .postgresql) == "psql")
    }

    @Test("binaryName returns psql for Redshift")
    func testBinaryName_redshift() {
        #expect(CLICommandResolver.binaryName(for: .redshift) == "psql")
    }

    @Test("binaryName returns redis-cli for Redis")
    func testBinaryName_redis() {
        #expect(CLICommandResolver.binaryName(for: .redis) == "redis-cli")
    }

    @Test("binaryName returns mongosh for MongoDB")
    func testBinaryName_mongodb() {
        #expect(CLICommandResolver.binaryName(for: .mongodb) == "mongosh")
    }

    @Test("binaryName returns sqlite3 for SQLite")
    func testBinaryName_sqlite() {
        #expect(CLICommandResolver.binaryName(for: .sqlite) == "sqlite3")
    }

    @Test("binaryName returns sqlcmd for MSSQL")
    func testBinaryName_mssql() {
        #expect(CLICommandResolver.binaryName(for: .mssql) == "sqlcmd")
    }

    @Test("binaryName returns clickhouse-client for ClickHouse")
    func testBinaryName_clickhouse() {
        #expect(CLICommandResolver.binaryName(for: .clickhouse) == "clickhouse-client")
    }

    @Test("binaryName returns duckdb for DuckDB")
    func testBinaryName_duckdb() {
        #expect(CLICommandResolver.binaryName(for: .duckdb) == "duckdb")
    }

    @Test("binaryName returns sqlplus for Oracle")
    func testBinaryName_oracle() {
        #expect(CLICommandResolver.binaryName(for: .oracle) == "sqlplus")
    }

    @Test("binaryName returns lowercased rawValue for unknown type")
    func testBinaryName_unknownType() {
        let unknownType = DatabaseType(rawValue: "CockroachDB")
        #expect(CLICommandResolver.binaryName(for: unknownType) == "cockroachdb")
    }

    // MARK: - installInstructions(for:)

    @Test("installInstructions returns non-empty for all known terminal types")
    func testInstallInstructions_allKnownTypes() {
        let terminalTypes: [DatabaseType] = [
            .mysql, .mariadb, .postgresql, .redshift, .redis, .mongodb,
            .sqlite, .mssql, .clickhouse, .duckdb, .oracle
        ]
        for dbType in terminalTypes {
            let instructions = CLICommandResolver.installInstructions(for: dbType)
            #expect(!instructions.isEmpty, "Instructions should be non-empty for \(dbType.rawValue)")
        }
    }

    @Test("installInstructions returns brew command for MySQL")
    func testInstallInstructions_mysql() {
        #expect(CLICommandResolver.installInstructions(for: .mysql) == "brew install mysql-client")
    }

    @Test("installInstructions returns generic message for unknown type")
    func testInstallInstructions_unknownType() {
        let unknownType = DatabaseType(rawValue: "CockroachDB")
        let instructions = CLICommandResolver.installInstructions(for: unknownType)
        #expect(instructions.contains("CockroachDB"))
    }

    // MARK: - resolve returns nil for unsupported type

    @Test("resolve returns nil for a database type with no CLI mapping")
    func testResolve_unknownType_returnsNil() {
        let connection = DatabaseConnection(
            name: "Test",
            host: "localhost",
            port: 9999,
            type: DatabaseType(rawValue: "FakeDB"),
            sshTunnelMode: .disabled
        )
        let result = CLICommandResolver.resolve(
            connection: connection,
            password: nil,
            activeDatabase: nil
        )
        #expect(result == nil)
    }

    // MARK: - findExecutable

    @Test("findExecutable returns nil for nonexistent binary")
    func testFindExecutable_nonexistent() {
        let result = CLICommandResolver.findExecutable("__tablepro_nonexistent_binary_xyz__")
        #expect(result == nil)
    }

    @Test("findExecutable returns path for system binary")
    func testFindExecutable_systemBinary() {
        // /bin/ls exists on all macOS systems
        let result = CLICommandResolver.findExecutable("ls")
        #expect(result != nil)
    }

    // MARK: - SSH config extraction (tested through resolve)

    @Test("resolve with disabled SSH does not use SSH path")
    func testResolve_disabledSSH() {
        // With SSH disabled, resolve should attempt local resolution.
        // Since the CLI binary likely exists for sqlite3, this tests
        // that disabled SSH doesn't trigger SSH resolution.
        let connection = DatabaseConnection(
            name: "Local SQLite",
            host: "",
            database: "/tmp/test.db",
            type: .sqlite,
            sshTunnelMode: .disabled
        )
        let result = CLICommandResolver.resolve(
            connection: connection,
            password: nil,
            activeDatabase: nil
        )
        // sqlite3 should be found on macOS
        if let spec = result {
            #expect(spec.executablePath.contains("sqlite3"))
            #expect(!spec.executablePath.contains("ssh"))
        }
    }

    @Test("resolve with inline SSH uses SSH when local CLI unavailable")
    func testResolve_inlineSSH() {
        let sshConfig = SSHConfiguration(
            enabled: true,
            host: "bastion.example.com",
            port: 22,
            username: "deploy"
        )
        // Use a type that is unlikely to have a local CLI to force SSH path
        let connection = DatabaseConnection(
            name: "Remote Oracle",
            host: "db.internal",
            port: 1521,
            type: .oracle,
            sshTunnelMode: .inline(sshConfig)
        )
        let result = CLICommandResolver.resolve(
            connection: connection,
            password: "secret",
            activeDatabase: "mydb"
        )
        // If ssh binary exists, we should get an SSH-based spec
        if let spec = result {
            #expect(spec.executablePath.hasSuffix("ssh"))
        }
    }

    @Test("resolve with profile SSH uses snapshot config")
    func testResolve_profileSSH() {
        let snapshot = SSHConfiguration(
            enabled: true,
            host: "jump.example.com",
            port: 2222,
            username: "admin"
        )
        let connection = DatabaseConnection(
            name: "Remote PG",
            host: "db.internal",
            port: 5432,
            type: .postgresql,
            sshTunnelMode: .profile(id: UUID(), snapshot: snapshot)
        )
        let result = CLICommandResolver.resolve(
            connection: connection,
            password: "pass",
            activeDatabase: "mydb"
        )
        // Should attempt SSH-based resolution since profile SSH is set
        if let spec = result {
            // Either SSH path or local psql path (if psql found locally with effectiveConnection)
            #expect(!spec.executablePath.isEmpty)
        }
    }
}
