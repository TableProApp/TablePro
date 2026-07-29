//
//  DatabaseConnectionDisplayTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("DatabaseConnection display")
struct DatabaseConnectionDisplayTests {
    @Test("Relational connection shows database after host")
    func relationalShowsDatabase() {
        let connection = DatabaseConnection(
            name: "Project", host: "localhost", port: 3_306,
            database: "myapp_production", type: .mysql
        )

        #expect(connection.connectionSubtitle == "localhost · myapp_production")
    }

    @Test("Non-default port is shown before the database")
    func nonDefaultPortShown() {
        let connection = DatabaseConnection(
            name: "Project", host: "localhost", port: 3_307,
            database: "myapp_production", type: .mysql
        )

        #expect(connection.connectionSubtitle == "localhost:3307 · myapp_production")
    }

    @Test("Empty database leaves no trailing separator")
    func emptyDatabaseHasNoSeparator() {
        let connection = DatabaseConnection(
            name: "Project", host: "localhost", port: 3_306,
            database: "", type: .mysql
        )

        #expect(connection.connectionSubtitle == "localhost")
    }

    @Test("PostgreSQL shows database on its default port")
    func postgresShowsDatabase() {
        let connection = DatabaseConnection(
            name: "Analytics", host: "db.example.com", port: 5_432,
            database: "analytics", type: .postgresql
        )

        #expect(connection.connectionSubtitle == "db.example.com · analytics")
    }

    @Test("Two same-named, same-host connections differ by database")
    func sameNameSameHostDifferByDatabase() {
        let staging = DatabaseConnection(
            name: "Acme", host: "10.0.0.5", port: 5_432, database: "acme_staging", type: .postgresql
        )
        let production = DatabaseConnection(
            name: "Acme", host: "10.0.0.5", port: 5_432, database: "acme_production", type: .postgresql
        )

        #expect(staging.connectionSubtitle != production.connectionSubtitle)
    }

    @Test("File-based connection shows the path without duplicating it")
    func fileBasedShowsPathOnce() {
        let connection = DatabaseConnection(
            name: "Local", host: "", port: 0,
            database: "/var/db/app.sqlite", type: .sqlite
        )

        #expect(connection.connectionSubtitle == "/var/db/app.sqlite")
    }

    @Test("File-based connection abbreviates a home-relative path with a tilde")
    func fileBasedAbbreviatesHomePath() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("databases/app.sqlite")
        let connection = DatabaseConnection(
            name: "Local", host: "", port: 0, database: path, type: .sqlite
        )

        #expect(connection.connectionSubtitle == "~/databases/app.sqlite")
    }

    @Test("Unix socket host is abbreviated and keeps the database segment")
    func unixSocketHostAbbreviatesAndKeepsDatabase() {
        let socket = (NSHomeDirectory() as NSString).appendingPathComponent("run/mysql.sock")
        let connection = DatabaseConnection(
            name: "Project", host: socket, port: 3_306,
            database: "appdb", type: .mysql
        )

        #expect(connection.connectionSubtitle == "~/run/mysql.sock · appdb")
    }

    @Test("File-based connection with no path falls back to the type name")
    func fileBasedEmptyFallsBackToType() {
        let connection = DatabaseConnection(
            name: "In-memory", host: "", port: 0, database: "", type: .duckdb
        )

        #expect(connection.connectionSubtitle == "DuckDB")
    }

    @Test("Redis shows the database index when set")
    func redisShowsIndex() {
        let connection = DatabaseConnection(
            name: "Cache", host: "localhost", port: 6_379,
            database: "", type: .redis, redisDatabase: 3
        )

        #expect(connection.connectionSubtitle == "localhost · db 3")
    }

    @Test("Redis without an index shows only the host")
    func redisWithoutIndexShowsHost() {
        let connection = DatabaseConnection(
            name: "Cache", host: "localhost", port: 6_379,
            database: "", type: .redis, redisDatabase: nil
        )

        #expect(connection.connectionSubtitle == "localhost")
    }

    @Test("Oracle shows the service name after the host")
    func oracleShowsServiceName() {
        let connection = DatabaseConnection(
            name: "ERP", host: "ora.example.com", port: 1_521,
            database: "ORCLPDB1", type: .oracle
        )

        #expect(connection.connectionSubtitle == "ora.example.com · ORCLPDB1")
    }

    @Test("MongoDB replica set shows host count and database")
    func mongoReplicaSetShowsCountAndDatabase() {
        let connection = DatabaseConnection(
            name: "Docs", host: "node1.example.com", port: 27_017,
            database: "appdb", type: .mongodb,
            additionalFields: ["mongoHosts": "node1.example.com,node2.example.com,node3.example.com"]
        )

        #expect(connection.connectionSubtitle == "node1.example.com (+2 more) · appdb")
    }

    @Test("SSH via segment comes last")
    func sshViaComesLast() {
        var sshConfig = SSHConfiguration()
        sshConfig.enabled = true
        sshConfig.host = "bastion.example.com"
        let connection = DatabaseConnection(
            name: "Project", host: "localhost", port: 3_306,
            database: "myapp", type: .mysql, sshConfig: sshConfig
        )

        #expect(connection.connectionSubtitle == "localhost · myapp · via bastion.example.com")
    }

    @Test("Unknown future type is treated like a database role")
    func unknownTypeUsesDatabaseRole() {
        let connection = DatabaseConnection(
            name: "Future", host: "future.example.com", port: 0,
            database: "mydb", type: DatabaseType(rawValue: "FutureDB")
        )

        #expect(connection.connectionSubtitle == "future.example.com · mydb")
    }
}
