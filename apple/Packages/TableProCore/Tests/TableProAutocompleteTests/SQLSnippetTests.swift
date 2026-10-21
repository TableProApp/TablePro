import Foundation
@testable import TableProAutocomplete
import Testing

struct SQLSnippetTests {
    private func text(_ snippet: SQLSnippet?, _ range: NSRange) -> String? {
        snippet.map { ($0.text as NSString).substring(with: range) }
    }

    @Test("Three numbered fields expand to their defaults in Tab order")
    func threeFields() throws {
        let snippet = try #require(SQLSnippet.parse("UPDATE ${1:users} SET ${2:name} = ${3:value}"))

        #expect(snippet.text == "UPDATE users SET name = value")
        #expect(snippet.fields.map { $0.number } == [1, 2, 3])
        #expect(snippet.fields.map { text(snippet, $0.ranges[0]) } == ["users", "name", "value"])
        #expect(snippet.finalRange == nil)
    }

    @Test("Fields are visited by number, not by position")
    func numberOrder() throws {
        let snippet = try #require(SQLSnippet.parse("${2:b} ${1:a} ${10:c}"))

        #expect(snippet.fields.map { $0.number } == [1, 2, 10])
        #expect(snippet.fields[0].ranges == [NSRange(location: 2, length: 1)])
    }

    @Test("The same number twice is one field with two ranges, the first default fills both")
    func mirrors() throws {
        let snippet = try #require(SQLSnippet.parse("SELECT ${1:id} FROM t WHERE ${1} > 0"))

        #expect(snippet.text == "SELECT id FROM t WHERE id > 0")
        #expect(snippet.fields.count == 1)
        #expect(snippet.fields[0].ranges == [NSRange(location: 7, length: 2), NSRange(location: 23, length: 2)])
    }

    @Test("A mirror written before its default still takes the default")
    func mirrorBeforeDefinition() throws {
        let snippet = try #require(SQLSnippet.parse("${1} = ${1:x}"))

        #expect(snippet.text == "x = x")
        #expect(snippet.fields[0].ranges.count == 2)
    }

    @Test("An empty field and the final stop")
    func emptyFieldAndFinal() throws {
        let snippet = try #require(SQLSnippet.parse("SELECT ${1} FROM t${0}"))

        #expect(snippet.text == "SELECT  FROM t")
        #expect(snippet.fields[0].ranges == [NSRange(location: 7, length: 0)])
        #expect(snippet.finalRange == NSRange(location: 14, length: 0))
    }

    @Test("A choice field shows its first option and keeps the list")
    func choice() throws {
        let snippet = try #require(SQLSnippet.parse("ORDER BY id ${1|ASC,DESC|}"))

        #expect(snippet.text == "ORDER BY id ASC")
        #expect(snippet.fields[0].choices == ["ASC", "DESC"])
        #expect(snippet.fields[0].ranges == [NSRange(location: 12, length: 3)])
    }

    @Test("A nested field sits inside its parent")
    func nested() throws {
        let snippet = try #require(SQLSnippet.parse("SELECT ${1:${2:*} FROM t}"))

        #expect(snippet.text == "SELECT * FROM t")
        #expect(snippet.fields[0].ranges == [NSRange(location: 7, length: 8)])
        #expect(snippet.fields[1].ranges == [NSRange(location: 7, length: 1)])
    }

    @Test(
        "PostgreSQL parameters, dollar quotes and other dollar text stay literal",
        arguments: [
            "SELECT * FROM t WHERE id = $1",
            "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql",
            "SELECT $tag$text$tag$",
            "SELECT '${name}'",
            "SELECT '${1:open'",
            "SELECT '${1|a,b}'",
            "SELECT ${}",
            "SELECT \\d"
        ]
    )
    func literalDollars(_ template: String) {
        #expect(SQLSnippet.parse(template) == nil)
    }

    @Test("A bare $1 next to a field stays literal")
    func bareParameterBesideField() throws {
        let snippet = try #require(SQLSnippet.parse("SELECT * FROM ${1:t} WHERE id = $1"))

        #expect(snippet.text == "SELECT * FROM t WHERE id = $1")
        #expect(snippet.fields[0].ranges == [NSRange(location: 14, length: 1)])
    }

    @Test(";; is the final stop, and only the first one counts")
    func markerIsFinal() throws {
        let snippet = try #require(SQLSnippet.parse("WHERE a = ;; AND b = ;;"))

        #expect(snippet.text == "WHERE a =  AND b = ;;")
        #expect(snippet.fields.isEmpty)
        #expect(snippet.finalRange == NSRange(location: 10, length: 0))
    }

    @Test(";; stays literal when ${0} sets the final stop")
    func explicitFinalWins() throws {
        let snippet = try #require(SQLSnippet.parse("SELECT ;; ${1:x}${0}"))

        #expect(snippet.text == "SELECT ;; x")
        #expect(snippet.finalRange == NSRange(location: 11, length: 0))
    }

    @Test(";; inside a default is text")
    func markerInsideDefault() throws {
        let snippet = try #require(SQLSnippet.parse("${1:a;;b}"))

        #expect(snippet.text == "a;;b")
        #expect(snippet.finalRange == nil)
    }

    @Test("Escapes inside a default and a choice, and \\${ at the top level")
    func escapes() throws {
        let snippet = try #require(SQLSnippet.parse(#"\${1} ${1:a\}b\$c\\d} ${2|x\,y,z\|w|}"#))

        #expect(snippet.text == #"${1} a}b$c\d x,y"#)
        #expect(snippet.fields[1].choices == ["x,y", "z|w"])
    }

    @Test("A field nested in a mirrored default is mirrored too")
    func nestedFieldInMirror() throws {
        let snippet = try #require(SQLSnippet.parse("${1:${2:x}} ${1}"))

        #expect(snippet.text == "x x")
        #expect(snippet.fields[1].ranges == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
    }

    @Test("Mirrors that expand past the limit leave the template as written")
    func expansionLimit() {
        let template = (1..<30).map { "${\($0):${\($0 + 1)}${\($0 + 1)}}" }.joined(separator: " ") + " ${30:x}"

        #expect(SQLSnippet.parse(template) == nil)
    }

    @Test("A field inside an occurrence of its own number has no range of its own")
    func selfNesting() throws {
        let snippet = try #require(SQLSnippet.parse("${1:a ${1} b}"))

        #expect(snippet.text == "a  b")
        #expect(snippet.fields[0].ranges == [NSRange(location: 0, length: 4)])
    }

    @Test("Offsets count UTF-16 units after multibyte text")
    func multibyte() throws {
        let prefix = "-- ghi chú 🙂\nSELECT "
        let snippet = try #require(SQLSnippet.parse(prefix + "${1:x}"))

        #expect(snippet.fields[0].ranges == [NSRange(location: (prefix as NSString).length, length: 1)])
    }

    @Test("Nesting past the limit leaves the template as written")
    func depthLimit() {
        let template = String(repeating: "${1:", count: 200) + String(repeating: "}", count: 200)

        #expect(SQLSnippet.parse(template) == nil)
    }

    @Test("Many unclosed fields fail once instead of backtracking")
    func unclosedFieldsStayLinear() {
        #expect(SQLSnippet.parse("SELECT ${1:a" + String(repeating: " ${2:b} $3", count: 20_000)) == nil)
    }

    @Test("One unclosed field leaves the whole template as written")
    func unclosedFieldKeepsTemplate() {
        #expect(SQLSnippet.parse("SELECT ${1:a} FROM ${2:t") == nil)
    }
}
