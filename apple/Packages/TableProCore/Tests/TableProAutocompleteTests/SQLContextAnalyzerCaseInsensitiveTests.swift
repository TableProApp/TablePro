@testable import TableProAutocomplete
import Testing

struct SQLContextAnalyzerCaseInsensitiveTests {
    private let analyzer = SQLContextAnalyzer()

    // MARK: - SELECT

    @Test("SELECT is detected in any case", arguments: [
        "SELECT ",
        "select ",
        "Select ",
    ])
    func selectInAnyCase(_ query: String) {
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .select)
    }

    // MARK: - WHERE

    @Test("WHERE is detected in any case, even with every keyword mixed", arguments: [
        "SELECT * FROM users WHERE ",
        "select * from users where ",
        "Select * From users Where ",
        "sElEcT * fRoM users wHeRe ",
    ])
    func whereInAnyCase(_ query: String) {
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .where_)
    }

    // MARK: - FROM

    @Test("FROM and DELETE FROM are detected in any case", arguments: [
        "SELECT * FROM ",
        "select * from ",
        "Select * From ",
        "DELETE FROM ",
        "delete from ",
    ])
    func fromInAnyCase(_ query: String) {
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .from)
    }

    // MARK: - INSERT INTO

    @Test("INSERT INTO is detected in any case", arguments: [
        "INSERT INTO ",
        "insert into ",
        "Insert Into ",
    ])
    func insertIntoInAnyCase(_ query: String) {
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .into)
    }

    // MARK: - UPDATE SET

    @Test("UPDATE SET is detected in any case", arguments: [
        "UPDATE users SET ",
        "update users set ",
        "Update users Set ",
    ])
    func updateSetInAnyCase(_ query: String) {
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .set)
    }

    // MARK: - ORDER BY

    @Test("ORDER BY is detected in any case, even after a randomly cased query", arguments: [
        "SELECT * FROM users ORDER BY ",
        "select * from users order by ",
        "Select * From users Order By ",
        "SeLeCt id, name FrOm users WhErE active = 1 OrDeR bY ",
    ])
    func orderByInAnyCase(_ query: String) {
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .orderBy)
    }

    // MARK: - GROUP BY

    @Test("GROUP BY is detected in any case", arguments: [
        "SELECT * FROM users GROUP BY ",
        "select * from users group by ",
    ])
    func groupByInAnyCase(_ query: String) {
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .groupBy)
    }

    // MARK: - HAVING

    @Test("HAVING is detected in any case", arguments: [
        "SELECT COUNT(*) FROM users GROUP BY status HAVING ",
        "select count(*) from users group by status having ",
    ])
    func havingInAnyCase(_ query: String) {
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .having)
    }

    // MARK: - JOIN

    @Test("JOIN and LEFT JOIN are detected in any case", arguments: [
        "SELECT * FROM users JOIN ",
        "select * from users join ",
        "select * from users left join ",
    ])
    func joinInAnyCase(_ query: String) {
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .join)
    }

    // MARK: - ALTER TABLE

    @Test("ALTER TABLE is detected in lowercase and mixed case", arguments: [
        "alter table users ",
        "Alter Table users ",
    ])
    func alterTableInAnyCase(_ query: String) {
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .alterTable)
    }
}
