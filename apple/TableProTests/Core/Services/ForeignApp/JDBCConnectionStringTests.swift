//
//  JDBCConnectionStringTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import TableProPluginKit
import Testing

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

    @Test("A BigQuery URL names the API host and the project")
    func bigQuery() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:bigquery://https://www.googleapis.com/bigquery/v2;ProjectId=my-project;OAuthType=3",
            subprotocol: "bigquery"
        )
        #expect(endpoint?.host == "https://www.googleapis.com/bigquery/v2")
        #expect(endpoint?.port == nil)
        #expect(endpoint?.database == "my-project")
    }

    @Test("A native MongoDB URL names its first host and database")
    func nativeMongo() {
        let endpoint = JDBCConnectionString.parse(
            url: "mongodb://app:secret@mongo1.example:27018,mongo2.example/shop?replicaSet=rs0",
            subprotocol: ""
        )
        #expect(endpoint?.host == "mongo1.example")
        #expect(endpoint?.port == 27_018)
        #expect(endpoint?.database == "shop")
        #expect(endpoint?.username == "app")

        let seeded = JDBCConnectionString.parse(url: "mongodb+srv://cluster0.example.net/app", subprotocol: "")
        #expect(seeded?.host == "cluster0.example.net")
        #expect(seeded?.port == nil)
    }

    @Test("A MongoDB URL keeps its seed list and its auth database as driver fields")
    func mongoURLFields() {
        let fields = JDBCConnectionString.urlFields("mongodb+srv://cluster0.example.net/app?authSource=admin&retryWrites=true")
        #expect(fields == ["mongoUseSrv": "true", "mongoAuthSource": "admin"])
        #expect(JDBCConnectionString.urlFields("jdbc:mongodb://h/app?authSource=ops") == ["mongoAuthSource": "ops"])
        #expect(JDBCConnectionString.urlFields("jdbc:postgresql://db/app?authSource=admin").isEmpty)
    }

    @Test("A URL names its user, decoded, but never its password")
    func urlUser() {
        let endpoint = JDBCConnectionString.parse(url: "mongodb://alice%40corp:s3cret@db.example/shop", subprotocol: "")
        #expect(endpoint?.username == "alice@corp")
        #expect(endpoint?.host == "db.example")
        #expect(JDBCConnectionString.parse(url: "jdbc:postgresql://db/app", subprotocol: "postgresql")?.username == nil)
    }

    @Test("A user parameter names the user in its own case")
    func userParameter() {
        let endpoint = JDBCConnectionString.parse(
            url: "jdbc:postgresql://db/app?user=Alice&sslmode=require",
            subprotocol: "postgresql"
        )
        #expect(endpoint?.username == "Alice")
        let server = JDBCConnectionString.parse(
            url: "jdbc:sqlserver://db:1433;databaseName=app;user=Sales",
            subprotocol: "sqlserver"
        )
        #expect(server?.username == "Sales")
    }

    @Test("A SQL Server instance keeps the port named after it")
    func sqlServerInstancePort() {
        let endpoint = JDBCConnectionString.parse(url: "jdbc:sqlserver://db\\SALES:1444;databaseName=app", subprotocol: "sqlserver")
        #expect(endpoint?.host == "db")
        #expect(endpoint?.port == 1_444)
        #expect(endpoint?.database == "app")
        let bare = JDBCConnectionString.parse(url: "jdbc:sqlserver://db\\SALES;databaseName=app", subprotocol: "sqlserver")
        #expect(bare?.host == "db")
        #expect(bare?.port == nil)
    }

    @Test("An escaped database name is decoded")
    func escapedDatabase() {
        let endpoint = JDBCConnectionString.parse(url: "jdbc:postgresql://db/team%20db?ssl=true", subprotocol: "postgresql")
        #expect(endpoint?.database == "team db")
        #expect(JDBCConnectionString.percentDecoded("100%zz%4") == "100%zz%4")
    }

    @Test("Only sslmode, a secure scheme and a seed list are read; every other TLS switch is unread")
    func urlTLS() {
        #expect(JDBCConnectionString.tls(of: "jdbc:postgresql://db/app?sslmode=verify-full") == .mode(.verifyIdentity))
        #expect(JDBCConnectionString.tls(of: "jdbc:postgresql://db/app?sslmode=require") == .mode(.required))
        #expect(JDBCConnectionString.tls(of: "jdbc:mariadb://db/app?sslMode=trust") == .mode(.required))
        #expect(JDBCConnectionString.tls(of: "jdbc:mysql://db/app?sslMode=VERIFY_IDENTITY") == .mode(.verifyIdentity))
        #expect(JDBCConnectionString.tls(of: "jdbc:postgresql://db/app?sslmode=disable") == .mode(.disabled))
        #expect(JDBCConnectionString.tls(of: "mongodb+srv://cluster.example/app") == .mode(.verifyIdentity))
        #expect(JDBCConnectionString.tls(of: "jdbc:clickhouse:https://db.example:8443/default") == .mode(.verifyIdentity))
        #expect(JDBCConnectionString.tls(of: "jdbc:clickhouse:http://db.example:8123/default") == JDBCConnectionString.TLS.none)
        #expect(JDBCConnectionString.tls(of: "jdbc:postgresql://db/app") == JDBCConnectionString.TLS.none)
        #expect(JDBCConnectionString.tls(of: "mongodb://db/app") == JDBCConnectionString.TLS.none)
        let unread = [
            "jdbc:postgresql://db/app?ssl=true",
            "jdbc:postgresql://db/app?sslmode=verify-full&sslrootcert=/ca.pem",
            "jdbc:mysql://db/app?useSSL=true&requireSSL=false",
            "jdbc:sqlserver://db:1433;databaseName=app;encrypt=true",
            "mongodb+srv://cluster.example/app?tls=false",
            "jdbc:postgresql://db/app?sslmode=sometimes",
            "jdbc:postgresql://db/app?sslmode=require&sslpassword=hunter2"
        ]
        for url in unread {
            guard case .unread(let written) = JDBCConnectionString.tls(of: url) else {
                Issue.record("Expected \(url) to be unread")
                continue
            }
            #expect(PortableSSLMode(carrying: written) == nil, "\(url)")
            #expect(!written.contains("hunter2"), "\(url)")
        }
    }

    @Test("A secure scheme still names its host and port")
    func secureSchemeEndpoint() {
        let endpoint = JDBCConnectionString.parse(url: "jdbc:clickhouse:https://db.example:8443/default", subprotocol: "clickhouse")
        #expect(endpoint?.host == "db.example")
        #expect(endpoint?.port == 8_443)
    }
}
