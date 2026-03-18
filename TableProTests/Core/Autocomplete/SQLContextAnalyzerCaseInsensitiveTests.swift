//
//  SQLContextAnalyzerCaseInsensitiveTests.swift
//  TableProTests
//
//  Regression tests verifying clause detection works case-insensitively
//  after removal of uppercased() normalization.
//

@testable import TablePro
import Testing

@Suite("SQLContextAnalyzer Case-Insensitive Clause Detection")
struct SQLContextAnalyzerCaseInsensitiveTests {
    private let analyzer = SQLContextAnalyzer()

    // MARK: - SELECT

    @Test("Uppercase SELECT detected")
    func uppercaseSelect() {
        let query = "SELECT "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .select)
    }

    @Test("Lowercase select detected")
    func lowercaseSelect() {
        let query = "select "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .select)
    }

    @Test("Mixed case Select detected")
    func mixedCaseSelect() {
        let query = "Select "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .select)
    }

    // MARK: - WHERE

    @Test("Uppercase WHERE detected")
    func uppercaseWhere() {
        let query = "SELECT * FROM users WHERE "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .where_)
    }

    @Test("Lowercase where detected")
    func lowercaseWhere() {
        let query = "select * from users where "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .where_)
    }

    @Test("Mixed case Where detected")
    func mixedCaseWhere() {
        let query = "Select * From users Where "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .where_)
    }

    // MARK: - FROM

    @Test("Uppercase FROM detected")
    func uppercaseFrom() {
        let query = "SELECT * FROM "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .from)
    }

    @Test("Lowercase from detected")
    func lowercaseFrom() {
        let query = "select * from "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .from)
    }

    @Test("Mixed case From detected")
    func mixedCaseFrom() {
        let query = "Select * From "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .from)
    }

    // MARK: - INSERT INTO

    @Test("Uppercase INSERT INTO detected")
    func uppercaseInsertInto() {
        let query = "INSERT INTO "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .into)
    }

    @Test("Lowercase insert into detected")
    func lowercaseInsertInto() {
        let query = "insert into "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .into)
    }

    @Test("Mixed case Insert Into detected")
    func mixedCaseInsertInto() {
        let query = "Insert Into "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .into)
    }

    // MARK: - UPDATE SET

    @Test("Uppercase UPDATE SET detected")
    func uppercaseUpdateSet() {
        let query = "UPDATE users SET "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .set)
    }

    @Test("Lowercase update set detected")
    func lowercaseUpdateSet() {
        let query = "update users set "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .set)
    }

    @Test("Mixed case Update Set detected")
    func mixedCaseUpdateSet() {
        let query = "Update users Set "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .set)
    }

    // MARK: - DELETE FROM

    @Test("Uppercase DELETE FROM detected")
    func uppercaseDeleteFrom() {
        let query = "DELETE FROM "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .from)
    }

    @Test("Lowercase delete from detected")
    func lowercaseDeleteFrom() {
        let query = "delete from "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .from)
    }

    // MARK: - ORDER BY

    @Test("Uppercase ORDER BY detected")
    func uppercaseOrderBy() {
        let query = "SELECT * FROM users ORDER BY "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .orderBy)
    }

    @Test("Lowercase order by detected")
    func lowercaseOrderBy() {
        let query = "select * from users order by "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .orderBy)
    }

    @Test("Mixed case Order By detected")
    func mixedCaseOrderBy() {
        let query = "Select * From users Order By "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .orderBy)
    }

    // MARK: - GROUP BY

    @Test("Uppercase GROUP BY detected")
    func uppercaseGroupBy() {
        let query = "SELECT * FROM users GROUP BY "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .groupBy)
    }

    @Test("Lowercase group by detected")
    func lowercaseGroupBy() {
        let query = "select * from users group by "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .groupBy)
    }

    // MARK: - HAVING

    @Test("Uppercase HAVING detected")
    func uppercaseHaving() {
        let query = "SELECT COUNT(*) FROM users GROUP BY status HAVING "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .having)
    }

    @Test("Lowercase having detected")
    func lowercaseHaving() {
        let query = "select count(*) from users group by status having "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .having)
    }

    // MARK: - JOIN

    @Test("Uppercase JOIN detected")
    func uppercaseJoin() {
        let query = "SELECT * FROM users JOIN "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .join)
    }

    @Test("Lowercase join detected")
    func lowercaseJoin() {
        let query = "select * from users join "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .join)
    }

    @Test("Lowercase left join detected")
    func lowercaseLeftJoin() {
        let query = "select * from users left join "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .join)
    }

    // MARK: - ALTER TABLE

    @Test("Lowercase alter table detected")
    func lowercaseAlterTable() {
        let query = "alter table users "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .alterTable)
    }

    @Test("Mixed case Alter Table detected")
    func mixedCaseAlterTable() {
        let query = "Alter Table users "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .alterTable)
    }

    // MARK: - Mixed Case Full Queries

    @Test("Fully mixed case query detects correct clause")
    func fullyMixedCaseQuery() {
        let query = "sElEcT * fRoM users wHeRe "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .where_)
    }

    @Test("Random casing on complex query")
    func randomCasingComplexQuery() {
        let query = "SeLeCt id, name FrOm users WhErE active = 1 OrDeR bY "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .orderBy)
    }
}
