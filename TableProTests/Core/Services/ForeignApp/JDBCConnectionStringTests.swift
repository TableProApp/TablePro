//
//  JDBCConnectionStringTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("JDBCConnectionString")
struct JDBCConnectionStringTests {
    @Test("MySQL with port and database")
    func mysql() {
        let endpoint = JDBCConnectionString.parse(url: "jdbc:mysql://db.example.com:3307/shop", subprotocol: "mysql")
        #expect(endpoint?.host == "db.example.com")
        #expect(endpoint?.port == 3_307)
        #expect(endpoint?.database == "shop")
    }

    @Test("PostgreSQL strips query parameters")
    func postgresWithParams() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:postgresql://localhost:5432/app?sslmode=require&user=x",
            subprotocol: "postgresql"
        )
        #expect(endpoint?.host == "localhost")
        #expect(endpoint?.port == 5_432)
        #expect(endpoint?.database == "app")
    }

    @Test("MySQL without explicit port returns nil port")
    func mysqlNoPort() {
        let endpoint = JDBCConnectionString.parse(url: "jdbc:mysql://localhost/app", subprotocol: "mysql")
        #expect(endpoint?.host == "localhost")
        #expect(endpoint?.port == nil)
        #expect(endpoint?.database == "app")
    }

    @Test("Authority strips user info")
    func userInfo() {
        let endpoint = JDBCConnectionString.parse(url: "jdbc:mysql://root:pw@host:3306/db", subprotocol: "mysql")
        #expect(endpoint?.host == "host")
        #expect(endpoint?.port == 3_306)
    }

    @Test("IPv6 host in brackets")
    func ipv6() {
        let endpoint = JDBCConnectionString.parse(url: "jdbc:postgresql://[::1]:5432/db", subprotocol: "postgresql")
        #expect(endpoint?.host == "::1")
        #expect(endpoint?.port == 5_432)
        #expect(endpoint?.database == "db")
    }

    @Test("SQL Server uses semicolon properties for database")
    func sqlServerSemicolon() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:sqlserver://sql.example.com:1433;databaseName=Sales;encrypt=true",
            subprotocol: "sqlserver"
        )
        #expect(endpoint?.host == "sql.example.com")
        #expect(endpoint?.port == 1_433)
        #expect(endpoint?.database == "Sales")
    }

    @Test("SQL Server strips named instance")
    func sqlServerInstance() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:sqlserver://host\\SQLEXPRESS;databaseName=db",
            subprotocol: "sqlserver"
        )
        #expect(endpoint?.host == "host")
        #expect(endpoint?.database == "db")
    }

    @Test("jTDS SQL Server path form")
    func jtds() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:jtds:sqlserver://host:1433/mydb",
            subprotocol: "jtds"
        )
        #expect(endpoint?.host == "host")
        #expect(endpoint?.port == 1_433)
        #expect(endpoint?.database == "mydb")
    }

    @Test("Oracle SID form")
    func oracleSID() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:oracle:thin:@orahost:1521:ORCL",
            subprotocol: "oracle"
        )
        #expect(endpoint?.host == "orahost")
        #expect(endpoint?.port == 1_521)
        #expect(endpoint?.database == "ORCL")
    }

    @Test("Oracle service name form with //")
    func oracleService() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:oracle:thin:@//orahost:1521/PRODSVC",
            subprotocol: "oracle"
        )
        #expect(endpoint?.host == "orahost")
        #expect(endpoint?.port == 1_521)
        #expect(endpoint?.database == "PRODSVC")
    }

    @Test("Oracle service name form without //")
    func oracleServiceNoSlashes() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:oracle:thin:@orahost:1521/PRODSVC",
            subprotocol: "oracle"
        )
        #expect(endpoint?.host == "orahost")
        #expect(endpoint?.port == 1_521)
        #expect(endpoint?.database == "PRODSVC")
    }

    @Test("SQLite file path")
    func sqlite() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:sqlite:/Users/me/data/app.db",
            subprotocol: "sqlite"
        )
        #expect(endpoint?.host == "")
        #expect(endpoint?.port == nil)
        #expect(endpoint?.database == "/Users/me/data/app.db")
    }

    @Test("DuckDB file path")
    func duckdb() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:duckdb:/tmp/analytics.duckdb",
            subprotocol: "duckdb"
        )
        #expect(endpoint?.database == "/tmp/analytics.duckdb")
    }

    @Test("ClickHouse authority form")
    func clickhouse() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:clickhouse://ch.example.com:8123/metrics",
            subprotocol: "clickhouse"
        )
        #expect(endpoint?.host == "ch.example.com")
        #expect(endpoint?.port == 8_123)
        #expect(endpoint?.database == "metrics")
    }

    @Test("MongoDB with authSource query")
    func mongo() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:mongodb://mongo:27017/app?authSource=admin",
            subprotocol: "mongodb"
        )
        #expect(endpoint?.host == "mongo")
        #expect(endpoint?.port == 27_017)
        #expect(endpoint?.database == "app")
    }

    @Test("Non-jdbc url returns nil")
    func notJdbc() {
        #expect(JDBCConnectionString.parse(url: "mysql://x/y", subprotocol: "mysql") == nil)
    }
}
