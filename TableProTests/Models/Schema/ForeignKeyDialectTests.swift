//
//  ForeignKeyDialectTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Every expectation here was measured against the engine, or read off its grammar. The grid used
/// to offer all five actions everywhere, so a DuckDB user picking CASCADE reached
/// `Parser Error: FOREIGN KEY constraints cannot use CASCADE, SET NULL or SET DEFAULT`.
@Suite("Foreign key dialect")
struct ForeignKeyDialectTests {
    @Test("DuckDB takes only NO ACTION and RESTRICT, on delete and on update")
    func duckdb() {
        let dialect = ForeignKeyDialect.forType(.duckdb)
        #expect(dialect.deleteActions == [.noAction, .restrict])
        #expect(dialect.updateActions == [.noAction, .restrict])
        #expect(!dialect.supportsDelete(.cascade))
        #expect(!dialect.supportsUpdate(.setNull))
        #expect(!dialect.allowsQualifiedReferencedTable)
    }

    @Test("SQLite takes every action and no qualified parent")
    func sqlite() {
        let dialect = ForeignKeyDialect.forType(.sqlite)
        #expect(dialect.deleteActions.count == EditableForeignKeyDefinition.ReferentialAction.allCases.count)
        #expect(dialect.supportsUpdate(.setDefault))
        #expect(!dialect.allowsQualifiedReferencedTable)
        #expect(dialect.allowsOmittedReferencedColumns)
    }

    @Test("Oracle has no ON UPDATE clause at all")
    func oracle() {
        let dialect = ForeignKeyDialect.forType(.oracle)
        #expect(dialect.updateActions.isEmpty)
        #expect(dialect.deleteActions == [.noAction, .cascade, .setNull])
        #expect(!dialect.supportsDelete(.restrict))
    }

    /// NO ACTION writes no clause, so it is accepted even where the engine has no ON UPDATE
    /// grammar. Reading it as a listed action rejected every foreign key on Oracle, Dameng and
    /// Teradata, because an untouched row starts there.
    @Test("NO ACTION is accepted by every dialect, on delete and on update")
    func noActionIsAlwaysAccepted() {
        for type in [DatabaseType.oracle, .dameng, .teradata, .duckdb, .mssql, .mysql, .sqlite] {
            let dialect = ForeignKeyDialect.forType(type)
            #expect(dialect.supportsDelete(.noAction), "\(type.rawValue) must accept ON DELETE NO ACTION")
            #expect(dialect.supportsUpdate(.noAction), "\(type.rawValue) must accept ON UPDATE NO ACTION")
        }
    }

    @Test("SQL Server has no RESTRICT")
    func mssql() {
        let dialect = ForeignKeyDialect.forType(.mssql)
        #expect(!dialect.supportsDelete(.restrict))
        #expect(dialect.supportsDelete(.cascade))
        #expect(dialect.allowsQualifiedReferencedTable)
    }

    @Test("MySQL parses SET DEFAULT but InnoDB rejects the table, so it is not offered")
    func mysql() {
        let dialect = ForeignKeyDialect.forType(.mysql)
        #expect(!dialect.supportsDelete(.setDefault))
        #expect(!dialect.supportsUpdate(.setDefault))
        #expect(!dialect.allowsOmittedReferencedColumns)
    }

    @Test("Teradata carries no referential action")
    func teradata() {
        let dialect = ForeignKeyDialect.forType(.teradata)
        #expect(dialect.deleteActions == [.noAction])
        #expect(dialect.updateActions.isEmpty)
    }

    @Test("the libSQL family follows SQLite")
    func sqliteFamily() {
        for type in [DatabaseType.libsql, .turso, .cloudflareD1] {
            #expect(ForeignKeyDialect.forType(type) == ForeignKeyDialect.forType(.sqlite))
        }
    }

    @Test("an engine nobody has checked keeps the full vocabulary")
    func unknownEngine() {
        let dialect = ForeignKeyDialect.forType(DatabaseType(rawValue: "SomeFuturePlugin"))
        #expect(dialect.deleteActions == EditableForeignKeyDefinition.ReferentialAction.allCases)
        #expect(dialect.updateActions == EditableForeignKeyDefinition.ReferentialAction.allCases)
    }
}
