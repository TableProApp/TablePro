//
//  SyntaxHighlightingTests.swift
//  TableProTests
//
//  The grammars' capture names and the editor's `CaptureName` vocabulary are two hand-maintained lists that must
//  agree. When they drifted, `TreeSitterClient` dropped every capture it could not name and the token kept the plain
//  text colour, which reads as "this editor does not highlight that word" rather than as a defect (#2634).
//

import AppKit
import CodeEditLanguages
@testable import CodeEditSourceEditor
import Foundation
@testable import TablePro
import Testing

@Suite("Editor syntax highlighting")
struct SyntaxHighlightingTests {
    private static let bundledLanguageNames = ["sql", "json", "javascript", "jsx", "bash"]

    private static func language(named name: String) -> CodeLanguage? {
        switch name {
        case "sql": .sql
        case "json": .json
        case "javascript": .javascript
        case "jsx": .jsx
        case "bash": .bash
        default: nil
        }
    }

    private static let sql = """
    SELECT CAST(total AS INT), 42, NULL, 'abc'
    FROM orders o
    WHERE o.status IN ('a') AND o.total = 3
    GROUP BY o.status
    ORDER BY total DESC;
    """

    private static let json = """
    {"active": true, "count": 7, "note": "x"}
    """

    // MARK: - The two lists must agree

    @Test("Every bundled grammar's highlight query compiles", arguments: bundledLanguageNames)
    func bundledQueryCompiles(name: String) throws {
        let language = try #require(Self.language(named: name))
        let query = TreeSitterModel.shared.query(for: language.id)
        #expect(query != nil, "\(name) has no usable highlight query, so that editor shows no highlighting at all")
    }

    @Test("Every capture a bundled highlights query emits carries a colour or is deliberately unstyled")
    func everyCaptureNameResolves() throws {
        for name in Self.bundledLanguageNames {
            let language = try #require(Self.language(named: name))
            for url in try Self.highlightQueryURLs(for: language) {
                for capture in try Self.captureNames(in: url) {
                    let resolved = CaptureName.fromString(capture) != nil
                    let deliberate = CaptureName.unstyledGrammarCaptures.contains(capture)
                    #expect(
                        resolved || deliberate,
                        "\(name) emits @\(capture), which carries no colour and is not in unstyledGrammarCaptures"
                    )
                }
            }
        }
    }

    @Test("Deliberately unstyled captures stay unstyled", arguments: CaptureName.unstyledGrammarCaptures.sorted())
    func unstyledCapturesResolveToNothing(capture: String) {
        #expect(CaptureName.fromString(capture) == nil)
    }

    // MARK: - Capture resolution

    @Test(
        "Grammar capture names resolve to the editor's vocabulary",
        arguments: [
            ("keyword.operator", CaptureName.keyword),
            ("attribute", .keyword),
            ("storageclass", .keyword),
            ("type.qualifier", .keyword),
            ("type.builtin", .type),
            ("function.call", .function),
            ("function.builtin", .function),
            ("function.method", .method),
            ("constant", .constant),
            ("constant.builtin", .constant),
            ("operator", .operator),
            ("string.special.key", .string),
        ]
    )
    func grammarCaptureResolves(capture: String, expected: CaptureName) {
        #expect(CaptureName.fromString(capture) == expected)
    }

    @Test("An unknown capture name carries no colour")
    func unknownCaptureIsNil() {
        #expect(CaptureName.fromString("keyword.operator.something") == nil)
        #expect(CaptureName.fromString(nil) == nil)
    }

    @Test("A repeat capture spells itself without Swift's backticks")
    func repeatSpellsItselfPlainly() {
        #expect(CaptureName.repeat.stringValue == "repeat")
        #expect(CaptureName.fromString(CaptureName.repeat.stringValue) == .repeat)
    }

    // MARK: - The colours a reader actually sees

    @Test("SQL word tokens take their theme colour")
    func sqlWordTokenColors() throws {
        let palette = Palette.test
        let expected: [(String, NSColor)] = [
            ("SELECT", palette.keyword),
            ("IN", palette.keyword),
            ("AND", palette.keyword),
            ("BY", palette.keyword),
            ("DESC", palette.keyword),
            ("INT", palette.type),
            ("CAST", palette.function),
            ("42", palette.number),
            ("NULL", palette.value),
            ("orders", palette.type),
        ]

        let highlighted = try Self.highlight(Self.sql, language: .sql)
        for (token, color) in expected {
            let range = try Self.range(ofWord: token, in: Self.sql)
            #expect(Self.color(at: range, in: highlighted) == color, "\(token)")
        }
    }

    @Test("SQL string literals and symbolic operators take their own colours")
    func sqlLiteralAndOperatorColors() throws {
        let highlighted = try Self.highlight(Self.sql, language: .sql)
        let quoted = (Self.sql as NSString).range(of: "'abc'")
        #expect(Self.color(at: quoted, in: highlighted) == Palette.test.string)

        let equals = (Self.sql as NSString).range(of: "=")
        #expect(Self.color(at: equals, in: highlighted) == Palette.test.operatorColor)
    }

    @Test("SQL brackets stay at the plain text colour")
    func sqlBracketsAreUnstyled() throws {
        let highlighted = try Self.highlight(Self.sql, language: .sql)
        let bracket = (Self.sql as NSString).range(of: "(")
        #expect(Self.color(at: bracket, in: highlighted) == nil)
    }

    @Test("JSON literals and keys take their theme colour")
    func jsonTokenColors() throws {
        let highlighted = try Self.highlight(Self.json, language: .json)
        #expect(Self.color(at: try Self.range(ofWord: "true", in: Self.json), in: highlighted) == Palette.test.value)
        #expect(Self.color(at: try Self.range(ofWord: "7", in: Self.json), in: highlighted) == Palette.test.number)

        let key = (Self.json as NSString).range(of: "\"active\"")
        #expect(Self.color(at: key, in: highlighted) == Palette.test.string)
    }

    // MARK: - The theme's own wiring

    @MainActor
    @Test("The theme's operator and function colours reach the editor")
    func themeCarriesOperatorAndFunctionColors() {
        let colors = ThemeEngine.shared.colors.editor
        let theme = ThemeEngine.shared.makeEditorTheme()

        #expect(Self.sameColor(theme.operators.color, colors.operator))
        #expect(Self.sameColor(theme.functions.color, colors.function))
    }

    // MARK: - Helpers

    struct Palette {
        let text: NSColor
        let keyword: NSColor
        let type: NSColor
        let number: NSColor
        let string: NSColor
        let comment: NSColor
        let variable: NSColor
        let value: NSColor
        let operatorColor: NSColor
        let function: NSColor

        static var test: Palette {
            Palette(
                text: .systemGray,
                keyword: .systemBlue,
                type: .systemTeal,
                number: .systemPurple,
                string: .systemRed,
                comment: .systemGreen,
                variable: .systemOrange,
                value: .systemYellow,
                operatorColor: .systemBrown,
                function: .systemIndigo
            )
        }

        var editorTheme: EditorTheme {
            EditorTheme(
                text: .init(color: text),
                insertionPoint: text,
                invisibles: .init(color: text),
                background: .white,
                lineHighlight: .white,
                selection: .white,
                keywords: .init(color: keyword),
                commands: .init(color: keyword),
                types: .init(color: type),
                attributes: .init(color: variable),
                variables: .init(color: variable),
                values: .init(color: value),
                numbers: .init(color: number),
                strings: .init(color: string),
                characters: .init(color: string),
                comments: .init(color: comment),
                operators: .init(color: operatorColor),
                functions: .init(color: function)
            )
        }
    }

    private static func highlight(_ source: String, language: CodeLanguage) throws -> NSAttributedString {
        let highlighted = TreeSitterClient.quickHighlight(
            string: source,
            theme: Palette.test.editorTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            language: language
        )
        return try #require(highlighted)
    }

    private static func color(at range: NSRange, in string: NSAttributedString) -> NSColor? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return string.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    private static func range(ofWord word: String, in source: String) throws -> NSRange {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        let expression = try NSRegularExpression(pattern: pattern)
        let match = expression.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length))
        return try #require(match?.range, "\(word) does not appear in the sample")
    }

    private static func highlightQueryURLs(for language: CodeLanguage) throws -> [URL] {
        let primary = try #require(language.queryURL)
        let directory = primary.deletingLastPathComponent()
        let additional = (language.additionalHighlights ?? [])
            .filter { $0.hasPrefix("highlights") }
            .map { directory.appendingPathComponent("\($0).scm") }
        return additional + [primary]
    }

    private static func captureNames(in url: URL) throws -> Set<String> {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: "@([A-Za-z_][A-Za-z0-9_.]*)")
        var names: Set<String> = []
        for line in contents.components(separatedBy: .newlines) {
            let code = line.components(separatedBy: ";").first ?? line
            let scope = NSRange(location: 0, length: (code as NSString).length)
            for match in expression.matches(in: code, range: scope) {
                let name = (code as NSString).substring(with: match.range(at: 1))
                guard !name.hasPrefix("_") else { continue }
                names.insert(name)
            }
        }
        return names
    }

    private static func sameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.sRGB), let right = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(left.redComponent - right.redComponent) < 0.001
            && abs(left.greenComponent - right.greenComponent) < 0.001
            && abs(left.blueComponent - right.blueComponent) < 0.001
    }
}
