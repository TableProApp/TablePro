import Foundation
@testable import TableProTabularIO
import Testing

struct JSONTableWriterTests {
    private static let pretty = "[\n  {\n    \"id\": 1,\n    \"name\": \"Ann\",\n    \"tags\": [ \"a\", \"b\" ]\n  },\n  {\n    \"id\": 2,\n    \"name\": \"Bob\"\n  }\n]\n"
    private static let compact = #"[{"id":1,"name":"Ann"},{"id":2,"name":"Bob"}]"#

    private func replace(_ key: String, with literal: String) -> JSONObjectEdit {
        JSONObjectEdit(edits: [JSONMemberEdit(sourceKey: key, change: .replace(with: literal))])
    }

    private func member(_ key: String, _ literal: String) -> JSONNewMember {
        JSONNewMember(key: key, literal: literal)
    }

    private func rewrite(
        _ text: String,
        kind: JSONTableFileKind = .jsonLines,
        keyChanges: [String: JSONMemberChange] = [:],
        rows: (JSONSource) -> [JSONOutputRow]
    ) async throws -> String {
        let source = try await JSONFixtures.source(text, kind: kind)
        return try JSONFixtures.written(source, rows: rows(source), keyChanges: keyChanges)
    }

    @Test func testUntouchedFilesRoundTripByteForByte() async throws {
        let fixtures: [(String, JSONTableFileKind)] = [
            (Self.pretty, .json),
            (Self.compact, .json),
            ("[ ]\n", .json),
            ("[]", .json),
            ("[\n  {\"a\":1}\n]", .json),
            ("{\"id\":1}\r\n{\"id\":2}\r\n", .jsonLines),
            ("\n{\"id\":1}\n\n\n{\"id\":2}\n  {\"id\":3}", .jsonLines),
            ("{\n \"a\": 1\n}\n{\"a\":2} {\"a\":3}\n", .jsonLines),
            ("", .jsonLines),
            ("\n\n", .jsonLines),
            ("{\"a\":{\"deep\":[1, {\"x\" : null}]} , \"b\" : \"\\u00e9\\n\"}\n", .jsonLines)
        ]
        for (text, kind) in fixtures {
            let written = try await rewrite(text, kind: kind) { JSONFixtures.untouchedRows(of: $0) }
            #expect(written == text, "\(text.debugDescription)")
        }
    }

    @Test func testByteOrderMarkSurvivesARoundTrip() async throws {
        let bytes = JSONByte.utf8ByteOrderMark + Array("[{\"a\":1}]\n".utf8)
        let source = try await JSONFixtures.source(bytes, kind: .json)
        #expect(try JSONTableWriter(source: source).encoded(rows: JSONFixtures.untouchedRows(of: source)) == bytes)
        let edited = try JSONTableWriter(source: source).encoded(rows: [.edited(0, replace("a", with: "2"))])
        #expect(edited == JSONByte.utf8ByteOrderMark + Array("[{\"a\":2}]\n".utf8))
    }

    @Test func testEditingAValueKeepsKeyOrderAndEveryOtherByte() async throws {
        let written = try await rewrite(Self.pretty, kind: .json) { _ in
            [.edited(0, replace("name", with: "\"Ann Lee\"")), .source(1)]
        }
        #expect(written == Self.pretty.replacingOccurrences(of: "\"Ann\"", with: "\"Ann Lee\""))
    }

    @Test func testEditingADuplicateKeyReplacesTheLastOccurrence() async throws {
        let written = try await rewrite("{\"a\":1, \"b\":2, \"a\":3}\n") { _ in [.edited(0, replace("a", with: "9"))] }
        #expect(written == "{\"a\":1, \"b\":2, \"a\":9}\n")
    }

    @Test func testNullEmptyStringAndMissingAreWrittenDistinctly() async throws {
        let edit = JSONObjectEdit(
            edits: [
                JSONMemberEdit(sourceKey: "a", change: .replace(with: try JSONValueTyping.literal(for: "null", originalKind: .null))),
                JSONMemberEdit(sourceKey: "b", change: .replace(with: try JSONValueTyping.literal(for: "", originalKind: .text))),
                JSONMemberEdit(sourceKey: "c", change: .remove)
            ]
        )
        let written = try await rewrite(#"{"a":1,"b":"x","c":true,"d":1}"#) { _ in [.edited(0, edit)] }
        #expect(written == #"{"a":null,"b":"","d":1}"#)
        let reread = try await JSONFixtures.source(written)
        #expect(reread.cells(row: 0).map(\.kind) == [.null, .text, .number])
    }

    @Test func testNumberLexemesAreWrittenExactly() async throws {
        let lexemes = ["1.0", "-0", "1e5", "12345678901234567890", "0.1"]
        let appended = try lexemes.enumerated().map { offset, lexeme in
            JSONNewMember(key: "n\(offset)", literal: try JSONValueTyping.literal(for: lexeme, originalKind: .number))
        }
        let written = try await rewrite(#"{"n":5}"#) { _ in [.edited(0, JSONObjectEdit(appended: appended))] }
        #expect(written == #"{"n":5,"n0":1.0,"n1":-0,"n2":1e5,"n3":12345678901234567890,"n4":0.1}"#)
        let reread = try await JSONFixtures.source(written)
        #expect(Array(JSONFixtures.texts(reread, row: 0).dropFirst()) == lexemes)
    }

    @Test func testReplacingANestedValueWritesTheNewLiteral() async throws {
        let written = try await rewrite(Self.pretty, kind: .json) { _ in
            [.edited(0, replace("tags", with: #"["c"]"#)), .source(1)]
        }
        #expect(written == Self.pretty.replacingOccurrences(of: "[ \"a\", \"b\" ]", with: #"["c"]"#))
    }

    @Test func testRemovingMembersKeepsTheNeighboursFormatting() async throws {
        let compactObject = #"{"a":1,"b":2,"c":3}"#
        let expectations: [(String, [String], String)] = [
            (compactObject, ["a"], #"{"b":2,"c":3}"#),
            (compactObject, ["b"], #"{"a":1,"c":3}"#),
            (compactObject, ["c"], #"{"a":1,"b":2}"#),
            (compactObject, ["a", "c"], #"{"b":2}"#),
            (compactObject, ["a", "b", "c"], "{}"),
            ("{\n  \"a\": 1,\n  \"b\": 2\n}", ["a"], "{\n  \"b\": 2\n}"),
            ("{\n  \"a\": 1,\n  \"b\": 2\n}", ["b"], "{\n  \"a\": 1\n}"),
            (#"{"a":1,"b":2,"a":3}"#, ["a"], #"{"b":2}"#)
        ]
        for (text, removed, expected) in expectations {
            let edit = JSONObjectEdit(edits: removed.map { JSONMemberEdit(sourceKey: $0, change: .remove) })
            let written = try await rewrite(text) { _ in [.edited(0, edit)] }
            #expect(written == expected, "\(text) removing \(removed)")
        }
    }

    @Test func testAppendedKeysFollowTheObjectsOwnStyle() async throws {
        let expectations: [(String, String)] = [
            ("{\n  \"a\": 1,\n  \"b\": 2\n}", "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}"),
            (#"{"a":1}"#, #"{"a":1,"c":3}"#),
            (#"{ "a" : 1 }"#, #"{ "a" : 1, "c" : 3 }"#),
            ("{}", #"{"c":3}"#),
            ("{ }", #"{"c":3}"#)
        ]
        for (text, expected) in expectations {
            let written = try await rewrite(text) { _ in [.edited(0, JSONObjectEdit(appended: [self.member("c", "3")]))] }
            #expect(written == expected, "\(text)")
        }
    }

    @Test func testReplacingEveryMemberKeepsTheObjectsIndentation() async throws {
        let edit = JSONObjectEdit(
            edits: [JSONMemberEdit(sourceKey: "a", change: .remove)],
            appended: [member("b", "2"), member("c", "3")]
        )
        let written = try await rewrite("{\n  \"a\": 1\n}") { _ in [.edited(0, edit)] }
        #expect(written == "{\n  \"b\": 2,\n  \"c\": 3\n}")
    }

    @Test func testAssigningAKeyTheRowLacksAppendsIt() async throws {
        let written = try await rewrite("{\"a\":1}\n{\"b\":5}\n") { _ in
            [.edited(0, self.replace("b", with: "2")), .source(1)]
        }
        #expect(written == "{\"a\":1,\"b\":2}\n{\"b\":5}\n")
    }

    @Test func testAppendingAKeyTheRowAlreadyHasReplacesItsValue() async throws {
        let written = try await rewrite(#"{"a":1,"b":2}"#) { _ in [.edited(0, JSONObjectEdit(appended: [self.member("a", "7")]))] }
        #expect(written == #"{"a":7,"b":2}"#)
    }

    @Test func testAnEditThatChangesNothingKeepsTheRowVerbatim() async throws {
        let text = "{ \"a\" :  1 }\n{\"a\":2}\n"
        let written = try await rewrite(text) { _ in [.edited(0, JSONObjectEdit()), .source(1)] }
        #expect(written == text)
    }

    @Test func testInsertedRowsInAnArrayUseTheFilesSeparator() async throws {
        let newRow = JSONOutputRow.new([member("id", "3"), member("name", "\"Cy\"")])
        let between = try await rewrite(Self.pretty, kind: .json) { _ in [.source(0), newRow, .source(1)] }
        let firstRow = "{\n    \"id\": 1,\n    \"name\": \"Ann\",\n    \"tags\": [ \"a\", \"b\" ]\n  }"
        let secondRow = "{\n    \"id\": 2,\n    \"name\": \"Bob\"\n  }"
        let insertedRow = #"{"id":3,"name":"Cy"}"#
        #expect(between == "[\n  \(firstRow),\n  \(insertedRow),\n  \(secondRow)\n]\n")
        let atEnd = try await rewrite(Self.pretty, kind: .json) { _ in [.source(0), .source(1), newRow] }
        #expect(atEnd == "[\n  \(firstRow),\n  \(secondRow),\n  \(insertedRow)\n]\n")
        let atStart = try await rewrite(Self.compact, kind: .json) { _ in [newRow, .source(0), .source(1)] }
        #expect(atStart == #"[{"id":3,"name":"Cy"},{"id":1,"name":"Ann"},{"id":2,"name":"Bob"}]"#)
    }

    @Test func testInsertedRowsInASmallArrayInferTheSeparator() async throws {
        let single = try await rewrite("[\n  {\"a\":1}\n]", kind: .json) { _ in [.source(0), .new([self.member("a", "2")])] }
        #expect(single == "[\n  {\"a\":1},\n  {\"a\":2}\n]")
        let empty = try await rewrite("[ ]\n", kind: .json) { _ in [.new([self.member("a", "1")]), .new([self.member("a", "2")])] }
        #expect(empty == "[{\"a\":1},{\"a\":2}]\n")
    }

    @Test func testInsertedRowsInJSONLinesUseTheFilesLineEnding() async throws {
        let crlf = try await rewrite("{\"id\":1}\r\n{\"id\":2}\r\n") { _ in [.source(0), .new([self.member("id", "3")]), .source(1)] }
        #expect(crlf == "{\"id\":1}\r\n{\"id\":3}\r\n{\"id\":2}\r\n")
        let noFinalNewline = try await rewrite("{\"id\":1}\n{\"id\":2}") { _ in [.source(0), .source(1), .new([self.member("id", "3")])] }
        #expect(noFinalNewline == "{\"id\":1}\n{\"id\":2}\n{\"id\":3}")
        let empty = try await rewrite("") { _ in [.new([self.member("a", "1")]), .new([self.member("a", "2")])] }
        #expect(empty == "{\"a\":1}\n{\"a\":2}\n")
    }

    @Test func testDeletedRowsKeepTheirNeighboursAndTheFinalNewlineState() async throws {
        let text = "\n{\"id\":1}\n\n\n{\"id\":2}\n  {\"id\":3}"
        let withoutMiddle = try await rewrite(text) { _ in [.source(0), .source(2)] }
        #expect(withoutMiddle == "\n{\"id\":1}\n\n\n{\"id\":3}")
        let withoutLast = try await rewrite(text) { _ in [.source(0), .source(1)] }
        #expect(withoutLast == "\n{\"id\":1}\n\n\n{\"id\":2}")
        let withoutAny = try await rewrite(text) { _ in [] }
        #expect(withoutAny == "")
        let prettyWithoutFirst = try await rewrite(Self.pretty, kind: .json) { _ in [.source(1)] }
        #expect(prettyWithoutFirst == "[\n  {\n    \"id\": 2,\n    \"name\": \"Bob\"\n  }\n]\n")
        let prettyWithoutAny = try await rewrite(Self.pretty, kind: .json) { _ in [] }
        #expect(prettyWithoutAny == "[]\n")
    }

    @Test func testReorderedRowsUseTheFilesSeparators() async throws {
        let array = try await rewrite(Self.compact, kind: .json) { _ in [.source(1), .source(0)] }
        #expect(array == #"[{"id":2,"name":"Bob"},{"id":1,"name":"Ann"}]"#)
        let lines = try await rewrite("{\"id\":1}\n{\"id\":2}\n") { _ in [.source(1), .source(0)] }
        #expect(lines == "{\"id\":2}\n{\"id\":1}\n")
    }

    @Test func testRenamingAColumnRenamesTheKeyInEveryObject() async throws {
        let text = "{\"id\":1,\"name\":\"x\"}\n{\"name\":\"y\"}\n{\"na\\u006de\":\"z\", \"name\":\"w\"}\n{\"id\":4}\n"
        let written = try await rewrite(text, keyChanges: ["name": .rename(to: "full \"name\"")]) { JSONFixtures.untouchedRows(of: $0) }
        #expect(written == "{\"id\":1,\"full \\\"name\\\"\":\"x\"}\n{\"full \\\"name\\\"\":\"y\"}\n{\"full \\\"name\\\"\":\"z\", \"full \\\"name\\\"\":\"w\"}\n{\"id\":4}\n")
    }

    @Test func testDeletingAColumnRemovesTheKeyFromEveryObject() async throws {
        let text = "{\"id\":1,\"name\":\"x\"}\n{\"name\":\"y\"}\n{\"id\":3}\n"
        let written = try await rewrite(text, keyChanges: ["name": .remove]) { JSONFixtures.untouchedRows(of: $0) }
        #expect(written == "{\"id\":1}\n{}\n{\"id\":3}\n")
    }

    @Test func testRowEditsCombineWithColumnChanges() async throws {
        let text = "{\"id\":1,\"name\":\"x\"}\n{\"id\":2}\n"
        let written = try await rewrite(text, keyChanges: ["name": .rename(to: "n"), "id": .remove]) { _ in
            [.edited(0, self.replace("name", with: "\"q\"")), .edited(1, self.replace("name", with: "\"r\""))]
        }
        #expect(written == "{\"n\":\"q\"}\n{\"n\":\"r\"}\n")
    }

    @Test func testRowEditOfARemovedColumnIsDropped() async throws {
        let written = try await rewrite("{\"a\":1,\"b\":2}\n", keyChanges: ["a": .remove]) { _ in
            [.edited(0, self.replace("a", with: "5"))]
        }
        #expect(written == "{\"b\":2}\n")
    }

    @Test func testRenameThatCollidesWithAnotherColumnThrows() async throws {
        let source = try await JSONFixtures.source("{\"id\":1,\"name\":\"x\"}\n")
        if let error = #expect(throws: (any Error).self, performing: { try JSONTableWriter(source: source, keyChanges: ["id": .rename(to: "name")]).encoded(rows: [.source(0)]) }) {
            #expect(error as? JSONTableWriteError == .duplicateKey("name"))
        }
        let swapped = try JSONFixtures.written(source, rows: [.source(0)], keyChanges: ["id": .rename(to: "name"), "name": .remove])
        #expect(swapped == "{\"name\":1}\n")
    }

    @Test func testInvalidLiteralsAreRefused() async throws {
        let lines = try await JSONFixtures.source("{\"a\":1}\n")
        if let error = #expect(throws: (any Error).self, performing: { try JSONTableWriter(source: lines).encoded(rows: [.edited(0, replace("a", with: "abc"))]) }) {
            #expect(error as? JSONTableWriteError == .invalidLiteral("abc"))
        }
        if let error = #expect(throws: (any Error).self, performing: { try JSONTableWriter(source: lines).encoded(rows: [.edited(0, replace("a", with: "[1,\n2]"))]) }) {
            #expect(error as? JSONTableWriteError == .literalSpansLines("[1,\n2]"))
        }
        if let error = #expect(throws: (any Error).self, performing: { try JSONTableWriter(source: lines).encoded(rows: [.new([member("a", "1 2")])]) }) {
            #expect(error as? JSONTableWriteError == .invalidLiteral("1 2"))
        }
        let array = try await JSONFixtures.source("[{\"a\":1}]", kind: .json)
        let written = try JSONTableWriter(source: array).encoded(rows: [.edited(0, replace("a", with: "[1,\n2]"))])
        #expect(try JSONFixtures.text(written) == "[{\"a\":[1,\n2]}]")
    }

    @Test func testNewRowWithDuplicateKeysThrows() async throws {
        let source = try await JSONFixtures.source("{\"a\":1}\n")
        if let error = #expect(throws: (any Error).self, performing: { try JSONTableWriter(source: source).encoded(rows: [.new([member("a", "1"), member("a", "2")])]) }) {
            #expect(error as? JSONTableWriteError == .duplicateKey("a"))
        }
    }

    @Test func testRowsTheSourceDoesNotHaveThrow() async throws {
        let source = try await JSONFixtures.source("{\"a\":1}\n")
        if let error = #expect(throws: (any Error).self, performing: { try JSONTableWriter(source: source).encoded(rows: [.source(5)]) }) {
            #expect(error as? JSONTableWriteError == .sourceRowUnavailable(5))
        }
        if let error = #expect(throws: (any Error).self, performing: { try JSONTableWriter(shape: .lines).encoded(rows: [.edited(0, JSONObjectEdit())]) }) {
            #expect(error as? JSONTableWriteError == .sourceRowUnavailable(0))
        }
    }

    @Test func testWriterWithoutASourceSerializesNewRows() throws {
        let rows: [JSONOutputRow] = [.new([member("a", "1")]), .new([member("b", "\"x\"")])]
        #expect(try JSONFixtures.text(JSONTableWriter(shape: .array).encoded(rows: rows)) == "[\n{\"a\":1},\n{\"b\":\"x\"}\n]\n")
        #expect(try JSONFixtures.text(JSONTableWriter(shape: .lines).encoded(rows: rows)) == "{\"a\":1}\n{\"b\":\"x\"}\n")
        #expect(try JSONFixtures.text(JSONTableWriter(shape: .array).encoded(rows: [])) == "[]\n")
        #expect(try JSONTableWriter(shape: .lines).encoded(rows: []).isEmpty)
    }

    @Test func testWritingToAFileMatchesTheEncodedBytes() async throws {
        let source = try await JSONFixtures.source(Self.pretty, kind: .json)
        let rows: [JSONOutputRow] = [.edited(1, replace("id", with: "20")), .source(0)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("json-writer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = JSONTableWriter(source: source)
        try writer.write(to: url, rows: rows)
        #expect(try Data(contentsOf: url) == Data(try writer.encoded(rows: rows)))
    }

    @Test func testWriteStopsWhenCancelled() async throws {
        let source = try await JSONFixtures.source(String(repeating: "{\"a\":\"\(String(repeating: "x", count: 100))\"}\n", count: 20_000))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("json-writer-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        if let error = #expect(throws: (any Error).self, performing: {
            try JSONTableWriter(source: source).write(to: url, rows: JSONFixtures.untouchedRows(of: source), isCancelled: { true })
        }) {
            #expect(error is TabularCancellation)
        }
    }
}
