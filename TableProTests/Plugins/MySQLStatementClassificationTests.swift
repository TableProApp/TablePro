//
//  MySQLStatementClassificationTests.swift
//  TableProTests
//

import Testing

@Suite("MySQL Statement Classification")
struct MySQLStatementClassificationTests {
    @Test("SELECT is read-only")
    func selectIsReadOnly() {
        #expect(mysqlStatementIsReadOnly("SELECT * FROM users"))
    }

    @Test("Leading whitespace and lowercase are handled")
    func whitespaceAndCase() {
        #expect(mysqlStatementIsReadOnly("   \n select 1"))
    }

    @Test("SHOW, DESCRIBE, and DESC are read-only")
    func showAndDescribe() {
        #expect(mysqlStatementIsReadOnly("SHOW TABLES"))
        #expect(mysqlStatementIsReadOnly("DESCRIBE users"))
        #expect(mysqlStatementIsReadOnly("DESC users"))
    }

    @Test("Mutating statements are not read-only")
    func mutatingStatements() {
        #expect(!mysqlStatementIsReadOnly("INSERT INTO users VALUES (1)"))
        #expect(!mysqlStatementIsReadOnly("UPDATE users SET name = 'a'"))
        #expect(!mysqlStatementIsReadOnly("DELETE FROM users"))
        #expect(!mysqlStatementIsReadOnly("CALL do_work()"))
        #expect(!mysqlStatementIsReadOnly("REPLACE INTO users VALUES (1)"))
        #expect(!mysqlStatementIsReadOnly("DROP TABLE users"))
    }

    @Test("A statement behind a leading comment is treated conservatively")
    func leadingCommentIsConservative() {
        #expect(!mysqlStatementIsReadOnly("/* note */ SELECT 1"))
        #expect(!mysqlStatementIsReadOnly("-- note\nSELECT 1"))
    }

    @Test("An empty statement is not read-only")
    func emptyIsNotReadOnly() {
        #expect(!mysqlStatementIsReadOnly(""))
        #expect(!mysqlStatementIsReadOnly("   "))
    }
}
