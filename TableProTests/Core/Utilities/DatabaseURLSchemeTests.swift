//
//  DatabaseURLSchemeTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Database URL Scheme Detection")
struct DatabaseURLSchemeTests {

    // MARK: - Standard Schemes

    @Test("MySQL scheme parses successfully")
    func mysqlScheme() {
        let result = ConnectionURLParser.parse("mysql://user:pass@localhost:3306/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mysql)
        #expect(parsed.host == "localhost")
        #expect(parsed.database == "mydb")
    }

    @Test("PostgreSQL scheme parses successfully")
    func postgresqlScheme() {
        let result = ConnectionURLParser.parse("postgresql://user:pass@localhost:5432/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .postgresql)
    }

    @Test("Postgres alias scheme parses successfully")
    func postgresAliasScheme() {
        let result = ConnectionURLParser.parse("postgres://user:pass@localhost/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .postgresql)
    }

    @Test("MariaDB scheme parses successfully")
    func mariadbScheme() {
        let result = ConnectionURLParser.parse("mariadb://user:pass@localhost:3306/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mariadb)
    }

    @Test("SQLite scheme parses successfully")
    func sqliteScheme() {
        let result = ConnectionURLParser.parse("sqlite:///path/to/database.db")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .sqlite)
        #expect(parsed.database == "/path/to/database.db")
    }

    @Test("MongoDB scheme parses successfully")
    func mongodbScheme() {
        let result = ConnectionURLParser.parse("mongodb://user:pass@localhost:27017/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mongodb)
    }

    @Test("MongoDB+SRV scheme parses and maps to mongodb type")
    func mongodbSrvScheme() {
        let result = ConnectionURLParser.parse("mongodb+srv://user:pass@cluster.example.com/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mongodb)
    }

    @Test("Redis scheme parses successfully")
    func redisScheme() {
        let result = ConnectionURLParser.parse("redis://user:pass@localhost:6379/0")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .redis)
        #expect(parsed.sslMode == nil)
    }

    @Test("Rediss scheme maps to redis type with SSL")
    func redissSchemeWithSsl() {
        let result = ConnectionURLParser.parse("rediss://user:pass@localhost:6379/0")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .redis)
        #expect(parsed.sslMode == .required)
    }

    @Test("Redshift scheme parses successfully")
    func redshiftScheme() {
        let result = ConnectionURLParser.parse("redshift://user:pass@cluster.redshift.amazonaws.com:5439/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .redshift)
    }

    @Test("MSSQL scheme parses successfully")
    func mssqlScheme() {
        let result = ConnectionURLParser.parse("mssql://user:pass@localhost:1433/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mssql)
    }

    @Test("SQL Server scheme parses successfully")
    func sqlserverScheme() {
        let result = ConnectionURLParser.parse("sqlserver://user:pass@localhost:1433/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mssql)
    }

    // MARK: - SSH Variants

    @Test("MySQL+SSH scheme parses successfully")
    func mysqlSshScheme() {
        let result = ConnectionURLParser.parse("mysql+ssh://sshuser@sshhost:22/dbuser:dbpass@dbhost/dbname")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mysql)
        #expect(parsed.sshHost == "sshhost")
        #expect(parsed.sshPort == 22)
        #expect(parsed.sshUsername == "sshuser")
        #expect(parsed.host == "dbhost")
        #expect(parsed.username == "dbuser")
        #expect(parsed.password == "dbpass")
        #expect(parsed.database == "dbname")
    }

    @Test("PostgreSQL+SSH scheme parses successfully")
    func postgresqlSshScheme() {
        let result = ConnectionURLParser.parse("postgresql+ssh://sshuser@sshhost:22/dbuser:dbpass@dbhost/dbname")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .postgresql)
        #expect(parsed.sshHost == "sshhost")
        #expect(parsed.sshUsername == "sshuser")
    }

    @Test("Postgres+SSH alias scheme parses successfully")
    func postgresSshAliasScheme() {
        let result = ConnectionURLParser.parse("postgres+ssh://sshuser@sshhost:22/dbuser:dbpass@dbhost/dbname")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .postgresql)
        #expect(parsed.sshHost == "sshhost")
    }

    @Test("MariaDB+SSH scheme parses successfully")
    func mariadbSshScheme() {
        let result = ConnectionURLParser.parse("mariadb+ssh://sshuser@sshhost:22/dbuser:dbpass@dbhost/dbname")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mariadb)
        #expect(parsed.sshHost == "sshhost")
        #expect(parsed.sshUsername == "sshuser")
    }

    // MARK: - Unsupported Schemes

    @Test("FTP scheme returns unsupported error")
    func ftpSchemeUnsupported() {
        let result = ConnectionURLParser.parse("ftp://user:pass@host/path")
        guard case .failure(let error) = result else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .unsupportedScheme("ftp"))
    }

    @Test("HTTP scheme returns unsupported error")
    func httpSchemeUnsupported() {
        let result = ConnectionURLParser.parse("http://example.com/api")
        guard case .failure(let error) = result else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .unsupportedScheme("http"))
    }

    @Test("Cassandra scheme parses successfully")
    func cassandraSchemeSupported() {
        let result = ConnectionURLParser.parse("cassandra://user:pass@host:9042/keyspace")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success, got: \(result)"); return
        }
        #expect(parsed.type == .cassandra)
        #expect(parsed.host == "host")
        #expect(parsed.port == nil) // 9042 is the default port, so parser normalizes to nil
        #expect(parsed.database == "keyspace")
        #expect(parsed.username == "user")
        #expect(parsed.password == "pass")
    }

    // MARK: - Case Insensitivity

    @Test("MySQL scheme is case-insensitive")
    func mysqlCaseInsensitive() {
        let result = ConnectionURLParser.parse("MySQL://user:pass@localhost:3306/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mysql)
    }

    @Test("PostgreSQL scheme is case-insensitive")
    func postgresqlCaseInsensitive() {
        let result = ConnectionURLParser.parse("POSTGRESQL://user:pass@localhost:5432/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .postgresql)
    }

    @Test("MSSQL scheme is case-insensitive")
    func mssqlCaseInsensitive() {
        let result = ConnectionURLParser.parse("MSSQL://user:pass@localhost:1433/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .mssql)
    }

    @Test("Mixed case scheme parses correctly")
    func mixedCaseScheme() {
        let result = ConnectionURLParser.parse("PostgreSQL://user:pass@localhost/mydb")
        guard case .success(let parsed) = result else {
            Issue.record("Expected success"); return
        }
        #expect(parsed.type == .postgresql)
    }
}
