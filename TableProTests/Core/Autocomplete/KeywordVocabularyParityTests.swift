//
//  KeywordVocabularyParityTests.swift
//  TableProTests
//
//  The completion provider and Auto-uppercase keep separate keyword lists. A word the popup
//  offers but `SQLKeywords.keywordSet` lacks stays lower case while the words around it change.
//

import Foundation
@testable import TablePro
import Testing

struct KeywordVocabularyParityTests {
    /// The uppercaser only ever looks at one word at a time, so a multi-word entry such as
    /// `ORDER BY` can never match and is not expected in the set.
    @Test("Every single-word keyword the provider offers is one the uppercaser knows")
    func offeredKeywordsAreUppercasable() async {
        let samples: [(text: String, clause: SQLClauseType)] = [
            ("", .unknown),
            ("SELECT ", .select),
            ("SELECT COUNT(", .select),
            ("SELECT * FROM users ", .from),
            ("INSERT INTO ", .into),
            ("SELECT * FROM users u ON ", .on),
            ("SELECT * FROM users WHERE ", .where_),
            ("SELECT * FROM users GROUP BY ", .groupBy),
            ("SELECT * FROM users ORDER BY ", .orderBy),
            ("UPDATE users SET ", .set),
            ("INSERT INTO users VALUES (", .values),
            ("SELECT CASE WHEN ", .caseExpression),
            ("SELECT * FROM users WHERE id IN (", .inList),
            ("SELECT * FROM users LIMIT ", .limit),
            ("ALTER TABLE users ", .alterTable),
            ("CREATE TABLE ", .createTable),
            ("CREATE TABLE test (id ", .createTable),
            ("ALTER TABLE users ADD COLUMN email ", .columnDef),
            ("SELECT * FROM users RETURNING ", .returning),
            ("SELECT 1 UNION ", .union),
            ("SELECT ROW_NUMBER() OVER (", .window),
            ("DROP TABLE ", .dropObject),
            ("CREATE INDEX ", .createIndex),
            ("CREATE INDEX idx ON users (", .createIndex),
            ("CREATE VIEW ", .createView),
        ]
        let provider = SQLCompletionProvider(schemaProvider: nil)
        // A table in scope ranks keywords ahead of functions, so none fall outside the candidate pool.
        let scopes: [[TableReference]?] = [nil, [TableReference(tableName: "users", alias: nil)]]

        var offered: Set<String> = []
        for sample in samples {
            for scope in scopes {
                let session = await provider.completionSession(
                    text: sample.text,
                    cursorPosition: (sample.text as NSString).length,
                    forcedTableReferences: scope
                )
                #expect(session.context.clauseType == sample.clause, "\"\(sample.text)\"")
                offered.formUnion(session.candidates.filter { $0.kind == .keyword }.map(\.label))
            }
        }

        let singleWords = offered.filter { label in
            label.allSatisfy { $0.isLetter } || label.contains("_")
        }
        #expect(singleWords.count > 50, "The provider offered only \(singleWords.sorted())")

        let unknown = singleWords
            .filter { !SQLKeywords.keywordSet.contains($0.lowercased()) }
            .sorted()

        #expect(
            unknown.isEmpty,
            """
            SQLCompletionProvider offers these as keyword completions, but SQLKeywords.keywordSet \
            does not contain them, so Auto-uppercase leaves them in whatever case the user typed \
            while uppercasing the words around them: \(unknown)
            """
        )
    }

    @Test("The uppercaser's set holds only single words, in lower case")
    func keywordSetShape() {
        #expect(!SQLKeywords.keywordSet.isEmpty)
        #expect(SQLKeywords.keywordSet.allSatisfy { !$0.contains(" ") })
        #expect(SQLKeywords.keywordSet.allSatisfy { $0 == $0.lowercased() })
    }

    /// The words the reported defect named, kept as an explicit list so a future edit that drops
    /// one fails here rather than quietly reopening the gap.
    @Test(
        "The keywords the gap was reported against are uppercasable",
        arguments: [
            "add", "change", "after", "comment", "collate", "charset", "engine",
            "tablespace", "merge", "upsert", "call", "use", "replace",
            "signed", "unsigned", "range", "groups", "btree", "hash", "gin", "gist"
        ]
    )
    func reportedKeywordsAreKnown(keyword: String) {
        #expect(SQLKeywords.keywordSet.contains(keyword))
    }

    /// `users` and `note` are identifiers and stay untouched.
    @Test("The reported statement uppercases every keyword and nothing else")
    func reportedStatementUppercasesConsistently() {
        let statement = "alter table users add column note text"
        let words = statement.split(separator: " ").map(String.init)
        let recognised = words.filter { SQLKeywords.keywordSet.contains($0) }
        #expect(recognised == ["alter", "table", "add", "column", "text"])

        let text = statement as NSString
        let endOfAdd = text.range(of: "add").location + 3
        #expect(KeywordUppercaseHelper.keywordBeforePosition(text, at: endOfAdd)?.word == "add")

        let endOfUsers = text.range(of: "users").location + 5
        #expect(KeywordUppercaseHelper.keywordBeforePosition(text, at: endOfUsers) == nil)
    }
}
