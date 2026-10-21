import Foundation
@testable import TableProMCP
import Testing

struct CLIRowWriterTests {
    private func render(_ set: CLIResultSet, _ format: CLIOutputFormat) -> String {
        var output = ""
        CLIRowWriter.write(set, as: format, to: &output)
        return output
    }

    private let mixed = CLIResultSet(
        columns: ["id", "note"],
        rows: [
            [.string("1"), .string("plain")],
            [.string("2"), .null],
            [.string("3"), .string("")],
            [.string("4"), .string("a,\"b\"\nc\td\\")]
        ]
    )

    @Test("CSV prints a header and one row for SELECT 1 AS n")
    func csvSingleRow() {
        let set = CLIResultSet(columns: ["n"], rows: [[.string("1")]])
        #expect(render(set, .csv) == "n\n1\n")
    }

    @Test("CSV keeps NULL apart from an empty string and quotes what needs it")
    func csvQuoting() {
        #expect(render(mixed, .csv) == """
        id,note
        1,plain
        2,
        3,""
        4,"a,""b""
        c\td\\"

        """)
    }

    @Test("TSV escapes tabs, newlines and backslashes so every row stays on one line")
    func tsvEscaping() {
        #expect(render(mixed, .tsv) == "id\tnote\n1\tplain\n2\t\n3\t\n4\ta,\"b\"\\nc\\td\\\\\n")
    }

    @Test("JSON is an array of objects in column order, with null for NULL")
    func jsonArray() {
        let set = CLIResultSet(columns: ["b", "a"], rows: [[.string("1"), .null], [.string("x\"y"), .string("2")]])
        let text = render(set, .json)
        #expect(text == "[\n  {\"b\":\"1\",\"a\":null},\n  {\"b\":\"x\\\"y\",\"a\":\"2\"}\n]\n")
        let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
        #expect(decoded?.count == 2)
    }

    @Test("JSON with no rows is an empty array, JSONL prints nothing")
    func emptyResults() {
        let set = CLIResultSet(columns: ["n"], rows: [])
        #expect(render(set, .json) == "[]\n")
        #expect(render(set, .jsonl).isEmpty)
        #expect(render(set, .csv) == "n\n")
    }

    @Test("JSONL prints one object per line")
    func jsonLines() {
        let set = CLIResultSet(columns: ["n"], rows: [[.string("1")], [.string("2")]])
        #expect(render(set, .jsonl) == "{\"n\":\"1\"}\n{\"n\":\"2\"}\n")
    }

    @Test("Repeated column names get distinct keys instead of overwriting each other")
    func duplicateKeys() {
        #expect(CLIRowWriter.uniqueKeys(["a", "a", "a_2", "b"]) == ["a", "a_2", "a_2_2", "b"])
    }

    @Test("Control characters are escaped in JSON strings")
    func jsonControlCharacters() {
        #expect(CLIRowWriter.jsonString("a\u{1}b\nc") == "\"a\\u0001b\\nc\"")
    }

    @Test("The table pads every column but the last and shows NULL")
    func table() {
        let set = CLIResultSet(
            columns: ["id", "email"],
            rows: [[.string("1"), .string("ada@example.com")], [.string("10"), .null]]
        )
        #expect(render(set, .table) == """
        id | email
        ---+----------------
        1  | ada@example.com
        10 | NULL

        """)
    }

    @Test("The table shows a stored escape sequence instead of sending it to the terminal")
    func tableEscapesControlCharacters() {
        #expect(CLIRowWriter.tableCell("\u{1B}[2Jgone") == "\\x1B[2Jgone")
        #expect(CLIRowWriter.tableCell("a\u{8}\u{9B}b") == "a\\x08\\x9Bb")
        #expect(CLIRowWriter.tableCell("tab\there\\") == "tab\\there\\\\")
        #expect(CLIRowWriter.tableCell("plain\\path") == "plain\\path")
        let set = CLIResultSet(columns: ["n\u{1B}"], rows: [[.string("\u{7}")]])
        #expect(render(set, .table) == "n\\x1B\n-----\n\\x07\n")
    }

    @Test("Several result sets in JSON stay one document")
    func jsonResultSets() {
        let sets = [
            CLIResultSet(columns: ["a"], rows: [[.string("1")]]),
            CLIResultSet(columns: [], rows: []),
            CLIResultSet(columns: ["b"], rows: [])
        ]
        var output = ""
        CLIRowWriter.write(sets, as: .json, to: &output)
        #expect(output == "[\n  [\n    {\"a\":\"1\"}\n  ],\n  []\n]\n")
        let decoded = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [Any]
        #expect(decoded?.count == 2)
    }

    @Test("Several result sets in CSV are separated by a blank line")
    func csvResultSets() {
        let sets = [CLIResultSet(columns: ["a"], rows: [[.string("1")]]), CLIResultSet(columns: ["b"], rows: [[.string("2")]])]
        var output = ""
        CLIRowWriter.write(sets, as: .csv, to: &output)
        #expect(output == "a\n1\n\nb\n2\n")
    }

    @Test("A statement with no columns prints nothing in any format")
    func noColumns() {
        let set = CLIResultSet(columns: [], rows: [])
        for format in CLIOutputFormat.allCases {
            #expect(render(set, format).isEmpty, "\(format)")
        }
    }
}
