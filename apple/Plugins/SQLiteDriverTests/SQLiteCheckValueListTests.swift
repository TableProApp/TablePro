//
//  SQLiteCheckValueListTests.swift
//  SQLiteDriverTests
//

import Foundation
import Testing

struct SQLiteCheckValueListTests {
    private func lists(_ body: String) -> [String: [String]] {
        SQLiteCheckConstraintParser.valueLists(inCreateStatement: "CREATE TABLE t (\(body))")
    }

    @Test("A column check lists its values under any spelling of the name", arguments: [
        "status TEXT CHECK (status IN ('a', 'b'))",
        "status TEXT CHECK (\"status\" IN ('a', 'b'))",
        "status TEXT CHECK (`status` IN ('a', 'b'))",
        "status TEXT CHECK ([status] IN ('a', 'b'))",
        "status TEXT CHECK((status IN ('a','b')))",
        "status TEXT check (status in ('a', 'b'))",
    ])
    func columnCheck(body: String) {
        #expect(lists(body) == ["status": ["a", "b"]])
    }

    @Test("A table check lists the values of the column it names")
    func tableCheck() {
        #expect(lists("id INTEGER, status TEXT, CONSTRAINT ck CHECK (status IN ('a', 'b'))") == ["status": ["a", "b"]])
        #expect(lists("id INTEGER, status TEXT, CHECK (status IN ('a'))") == ["status": ["a"]])
    }

    @Test("A doubled quote is one quote, and a backslash is kept as written")
    func literalEscapes() {
        #expect(lists("name TEXT CHECK (name IN ('it''s', 'a\\b'))") == ["name": ["it's", "a\\b"]])
    }

    @Test("A bare NULL allows no value to pick")
    func nullIsSkipped() {
        #expect(lists("status TEXT CHECK (status IN ('a', NULL, 'b'))") == ["status": ["a", "b"]])
        #expect(lists("status TEXT CHECK (status IN (NULL))").isEmpty)
    }

    @Test("The key folds ASCII case, as SQLite matches names")
    func keyFoldsCase() {
        let found = lists("Status TEXT CHECK (STATUS IN ('a', 'b'))")
        #expect(found == ["status": ["a", "b"]])
        #expect(SQLiteCheckConstraintParser.foldedName("Status") == "status")
    }

    @Test("Two lists on one column give no list: what both allow depends on its collation and NULLs")
    func twoChecksGiveNoList() {
        #expect(lists("status TEXT CHECK (status IN ('a', 'b')), CHECK (status IN ('b', 'c'))").isEmpty)
        #expect(lists("status TEXT COLLATE NOCASE CHECK (status IN ('a', 'b')), CHECK (status IN ('A', 'b'))").isEmpty)
        #expect(lists("status TEXT CHECK (status IN ('a', 'b')), CHECK (status IN ('a', NULL))").isEmpty)
    }

    @Test("Anything but a whole IN list of strings gives no list", arguments: [
        "status TEXT CHECK (status NOT IN ('a', 'b'))",
        "status TEXT CHECK (status IN ('a', 'b') OR status IS NULL)",
        "status TEXT CHECK (length(status) > 0 AND status IN ('a'))",
        "level INTEGER CHECK (level IN (1, 2, 3))",
        "level TEXT CHECK (level IN ('a', 2))",
        "status TEXT CHECK (status IN (SELECT s FROM allowed))",
        "status TEXT CHECK ('status' IN ('a', 'b'))",
        "status TEXT CHECK (status COLLATE NOCASE IN ('a'))",
        "status TEXT -- CHECK (status IN ('a', 'b'))\n",
        "status TEXT /* CHECK (status IN ('a')) */",
        "status TEXT DEFAULT 'CHECK (status IN (''a''))'",
        "check_status TEXT CHECK (check_status > 0)",
    ])
    func noList(body: String) {
        #expect(lists(body).isEmpty)
    }

    @Test("A statement that is not an ordinary table gives no list")
    func notATable() {
        let statement = "CREATE VIRTUAL TABLE t USING fts5(status)"
        #expect(SQLiteCheckConstraintParser.valueLists(inCreateStatement: statement).isEmpty)
    }
}
