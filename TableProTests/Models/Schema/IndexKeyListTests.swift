//
//  IndexKeyListTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct IndexKeyListTests {
    private static let columns = ["id", "tenant_id", "email", "a", "b", "v", "Weird, Name", "owner's_id", "lower(v)"]

    private func parts(
        _ text: String,
        on databaseType: DatabaseType = .postgresql,
        keeping expressions: [String] = []
    ) -> [IndexKeyPart] {
        IndexKeyList.parts(
            of: text,
            keeping: expressions,
            in: .testing(databaseType, columns: Self.columns)
        )
    }

    @Test("A typed expression keeps the comma inside its call")
    func typedExpressionKeepsItsComma() {
        #expect(parts("id, coalesce(a, b)") == [.column("id"), .expression("coalesce(a, b)")])
    }

    @Test("PostgreSQL's own deparse splits at the commas between keys only")
    func postgresDeparseSplits() {
        #expect(
            parts("((a || ', '::text) || b), id")
                == [.expression("((a || ', '::text) || b)"), .column("id")]
        )
        #expect(parts("(id + 1), (v)::character varying(10)") == [
            .expression("(id + 1)"), .expression("(v)::character varying(10)")
        ])
    }

    @Test("A CASE spread over several lines is one key")
    func multiLineCaseIsOneKey() {
        let text = "CASE\n    WHEN a IS NULL THEN b\n    ELSE a\nEND, id"
        #expect(parts(text) == [.expression("CASE\n    WHEN a IS NULL THEN b\n    ELSE a\nEND"), .column("id")])
    }

    @Test("A column whose name holds a comma or an apostrophe is matched whole")
    func knownColumnsAreMatchedWhole() {
        #expect(parts("Weird, Name, owner's_id") == [.column("Weird, Name"), .column("owner's_id")])
        #expect(parts("owner's_id, tenant_id") == [.column("owner's_id"), .column("tenant_id")])
    }

    @Test("A column name is found whatever its case, alone or in one pair of parentheses")
    func columnsResolveToTheirSpelling() {
        #expect(parts("EMAIL, (v), ( Tenant_ID )") == [.column("email"), .column("v"), .column("tenant_id")])
        #expect(parts("(nickname)") == [.column("nickname")])
    }

    @Test("A column named like an expression stays a column")
    func columnNamedLikeAnExpression() {
        #expect(parts("lower(v)") == [.column("lower(v)")])
    }

    @Test("A quoted identifier is a column, known or not")
    func quotedIdentifierIsAColumn() {
        #expect(parts(#""Weird, Name", "we ird""#) == [.column("Weird, Name"), .column("we ird")])
        #expect(parts("`email`", on: .mysql) == [.column("email")])
    }

    @Test("name(N) is a key prefix on MySQL and a function call on PostgreSQL")
    func prefixDependsOnTheEngine() {
        #expect(parts("email(20), id", on: .mysql) == [.prefixedColumn("email", length: 20), .column("id")])
        #expect(parts("EMAIL(20)", on: .mariadb) == [.prefixedColumn("email", length: 20)])
        #expect(parts("email(20)") == [.expression("email(20)")])
    }

    @Test("An engine that indexes no expression reads one as a column")
    func columnsOnlyEngine() {
        #expect(parts("lower(email)", on: .mssql) == [.column("lower(email)")])
        #expect(parts("email(20)", on: .oracle) == [.column("email(20)")])
        #expect(parts("lower(email)", on: .mariadb) == [.column("lower(email)")])
    }

    @Test("An expression the index already has stays an expression on any engine")
    func existingExpressionIsKept() {
        #expect(parts("f(20)", on: .mysql, keeping: ["f(20)"]) == [.expression("f(20)")])
        #expect(parts("UPPER([a]), id", on: .mssql, keeping: ["UPPER([a])"]) == [.expression("UPPER([a])"), .column("id")])
    }

    @Test("MySQL reads a backslash-escaped quote inside a string as part of it")
    func mysqlBackslashStrings() {
        #expect(
            parts(#"concat(`a`,_utf8mb4'it\'s, ok'), id"#, on: .mysql)
                == [.expression(#"concat(`a`,_utf8mb4'it\'s, ok')"#), .column("id")]
        )
    }

    @Test("PostgreSQL's literal backslash, escape strings and dollar quotes end where the server ends them")
    func postgresStrings() {
        #expect(parts(#"concat(a, 'x\'), id"#) == [.expression(#"concat(a, 'x\')"#), .column("id")])
        #expect(parts(#"concat(a, E'x\', y'), id"#) == [.expression(#"concat(a, E'x\', y')"#), .column("id")])
        #expect(parts("concat(a, $$x, y$$), id") == [.expression("concat(a, $$x, y$$)"), .column("id")])
    }

    @Test("A sort order cannot be typed into the key")
    func sortOrderIsNotAnExpression() {
        #expect(parts("lower(v) DESC") == [.column("lower(v) DESC")])
        #expect(parts("v asc, id") == [.column("v asc"), .column("id")])
        #expect(parts("lower(v) NULLS LAST") == [.column("lower(v) NULLS LAST")])
        #expect(parts("lower(v) COLLATE NOCASE DESC", on: .sqlite) == [.column("lower(v) COLLATE NOCASE DESC")])
        #expect(parts("(lower(v)) DESC", on: .mysql) == [.column("(lower(v)) DESC")])
    }

    @Test("Text that is not whole SQL is read as a column, so the column check names it")
    func brokenTextIsAColumn() {
        #expect(parts("lower(v") == [.column("lower(v")])
        #expect(parts("v)") == [.column("v)")])
        #expect(parts("lower('v)") == [.column("lower('v)")])
        #expect(parts("lower(v) -- note") == [.column("lower(v) -- note")])
        #expect(parts("lower(v); DROP TABLE t") == [.column("lower(v); DROP TABLE t")])
        #expect(parts("emial, id") == [.column("emial"), .column("id")])
    }

    @Test("Empty entries are dropped")
    func emptyEntriesAreDropped() {
        #expect(parts("").isEmpty)
        #expect(parts("a,,b,") == [.column("a"), .column("b")])
        #expect(parts("  , a ,  ") == [.column("a")])
    }

    @Test("Engines that write an expression key take one; the rest take column names")
    func dialectPerEngine() {
        for type in [DatabaseType.postgresql, .pglite, .sqlite, .libsql, .turso, .cloudflareD1, .duckdb] {
            #expect(IndexKeyDialect.forType(type) == IndexKeyDialect(takesPrefixLengths: false, takesExpressions: true))
        }
        #expect(IndexKeyDialect.forType(.mysql) == IndexKeyDialect(takesPrefixLengths: true, takesExpressions: true))
        for type in [DatabaseType.mariadb, .tidb, .oceanbase] {
            #expect(IndexKeyDialect.forType(type) == IndexKeyDialect(takesPrefixLengths: true, takesExpressions: false))
        }
        for type in [DatabaseType.cockroachdb, .redshift, .mssql, .oracle, DatabaseType(rawValue: "FutureDB")] {
            #expect(IndexKeyDialect.forType(type) == .columnsOnly)
        }
    }
}
