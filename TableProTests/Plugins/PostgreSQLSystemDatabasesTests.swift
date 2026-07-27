//
//  PostgreSQLSystemDatabasesTests.swift
//  TableProTests
//
//  Regression cover for #1967: the "postgres" database is an ordinary user
//  database created by initdb, not a system database, and hiding it made it
//  unreachable from every database list. The same mistake hid CockroachDB's
//  "defaultdb" and Redshift's "dev".
//

import Foundation
import Testing

@Suite("PostgreSQLSystemDatabases")
struct PostgreSQLSystemDatabasesTests {
    @Test("PostgreSQL has no system databases")
    func postgreSQLHasNone() {
        #expect(PostgreSQLSystemDatabases.postgreSQL.isEmpty)
    }

    @Test("The default postgres database is never a system database")
    func postgresDatabaseIsNotSystem() {
        #expect(!PostgreSQLSystemDatabases.postgreSQL.contains("postgres"))
        #expect(!PostgreSQLSystemDatabases.cockroachDB.contains("postgres"))
    }

    @Test("CockroachDB marks only its system catalog database")
    func cockroachMarksSystemOnly() {
        #expect(PostgreSQLSystemDatabases.cockroachDB == ["system"])
        #expect(!PostgreSQLSystemDatabases.cockroachDB.contains("defaultdb"))
    }

    @Test("Redshift marks only its internal database")
    func redshiftMarksInternalOnly() {
        #expect(PostgreSQLSystemDatabases.redshift == ["padb_harvest"])
        #expect(!PostgreSQLSystemDatabases.redshift.contains("dev"))
    }
}
