import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

struct LongSpanCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let text: String
    let engine: String
}

struct LocatedCutCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let text: String
    let engine: String
}

private final class CountingString: NSString {
    private let base: NSString
    private(set) var unitsRead = 0

    init(_ string: String) {
        base = string as NSString
        super.init()
    }

    override init() {
        base = ""
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var length: Int {
        base.length
    }

    override func character(at index: Int) -> unichar {
        unitsRead += 1
        return base.character(at: index)
    }

    override func getCharacters(_ buffer: UnsafeMutablePointer<unichar>, range: NSRange) {
        unitsRead += range.length
        base.getCharacters(buffer, range: range)
    }
}

struct SQLCompletionWindowTests {
    static let notes = String(repeating: "notes about the nightly load and its retries\n", count: 140)
    static let body = String(repeating: "  PERFORM pg_sleep(0);\n", count: 300)

    // The window's own analysis, shifted back onto the whole text, or nil when the cut answered without one.
    private func analyzedWindow(_ text: String, on engine: String) -> SQLContext? {
        let source = text as NSString
        let grammar = SQLLexicalGrammar.engine(engine)
        guard let window = SQLCompletionWindow.cut(source, around: source.length, grammar: grammar) else { return nil }
        return SQLContextAnalyzer()
            .analyze(query: window.text, cursorPosition: source.length - window.start, grammar: grammar)
            .offset(by: window.start)
    }

    @Test("A short text is analyzed whole")
    func shortTextIsWhole() {
        let window = SQLCompletionWindow.cut("SELECT * FROM or" as NSString, around: 16, grammar: .ansi)
        #expect(window?.text == "SELECT * FROM or")
        #expect(window?.start == 0)
    }

    @Test("A long statement is cut to the radius around the caret")
    func longTextIsCut() {
        let text = String(repeating: "x", count: 12_000) as NSString
        let window = SQLCompletionWindow.cut(text, around: 6_000, grammar: .ansi)
        #expect(window?.start == 1_000)
        #expect((window?.text as NSString?)?.length == 10_000)
    }

    @Test("The window is the caret's statement")
    func windowIsTheCaretStatement() {
        let text = "SELECT 1;\n" + String(repeating: "SELECT 2;\n", count: 2_000) + "SELECT * FROM or"
        let window = SQLCompletionWindow.cut(text as NSString, around: (text as NSString).length, grammar: .ansi)
        #expect(window?.text == "\nSELECT * FROM or")
    }

    @Test("A cut inside a long statement starts on a token boundary")
    func cutStartsOnATokenBoundary() throws {
        let text = "SELECT " + String(repeating: "alpha, ", count: 1_000) + "o FROM t WHERE x" as NSString
        let window = try #require(SQLCompletionWindow.cut(text, around: text.length, grammar: .ansi))
        #expect(window.start > text.length - SQLCompletionWindow.radius - 8)
        #expect(text.character(at: window.start - 1) == UInt16(UInt8(ascii: " ")))
    }

    @Test("A quoted name that holds the cut starts the window at its quote")
    func quotedNameAcrossTheCut() {
        let text = "SELECT * FROM \"" + String(repeating: "n", count: 6_000) + " Det" as NSString
        let window = SQLCompletionWindow.cut(text, around: text.length, grammar: .engine("PostgreSQL"))
        #expect(window?.start == 14)
    }

    // Starting the lexer at the cut read a comment or literal tail as code, and its real closer as an opener.
    @Test(
        "The caret inside a long comment or literal completes nothing",
        arguments: [
            LongSpanCase(testDescription: "A, block comment", text: "/*\n" + notes + "SELECT * FROM or", engine: "PostgreSQL"),
            LongSpanCase(
                testDescription: "C, dollar body",
                text: "CREATE FUNCTION f() RETURNS void AS $$\nBEGIN\n" + body + "  SELECT * FROM or",
                engine: "PostgreSQL"
            ),
            LongSpanCase(testDescription: "F, string", text: "INSERT INTO notes VALUES ('" + notes + "SELECT * FROM or", engine: "MySQL"),
            LongSpanCase(testDescription: "G, block comment", text: "/*\n" + notes + "SELECT * FROM or", engine: "MySQL")
        ]
    )
    func caretInsideALongSpanIsSilent(_ example: LongSpanCase) {
        let text = example.text as NSString
        #expect(SQLCompletionWindow.cut(text, around: text.length, grammar: .engine(example.engine)) == nil)
    }

    @Test(
        "Code after a long comment or literal completes as code",
        arguments: [
            LongSpanCase(
                testDescription: "B, comment with an apostrophe",
                text: "/*\n" + notes + "it's done */\nSELECT * FROM or",
                engine: "PostgreSQL"
            ),
            LongSpanCase(
                testDescription: "D, dollar body",
                text: "CREATE FUNCTION f() RETURNS void AS $$\nBEGIN\n" + body + "END\n$$ LANGUAGE plpgsql;\nSELECT * FROM or",
                engine: "PostgreSQL"
            ),
            LongSpanCase(
                testDescription: "E, string",
                text: "INSERT INTO notes VALUES ('" + notes + "');\nSELECT * FROM or",
                engine: "MySQL"
            ),
            LongSpanCase(testDescription: "H, short comment", text: "/* it's done */\nSELECT * FROM or", engine: "PostgreSQL")
        ]
    )
    func codeAfterALongSpanCompletes(_ example: LongSpanCase) throws {
        let context = try #require(analyzedWindow(example.text, on: example.engine))
        #expect(!context.isInsideString)
        #expect(!context.isInsideComment)
        #expect(context.clauseType == .from)
        #expect(context.prefix == "or")
        #expect(context.prefixRange.upperBound == (example.text as NSString).length)
    }

    @Test("A comment that holds the cut but ends before the caret is skipped whole")
    func commentAcrossTheCutInOneStatement() throws {
        let text = "SELECT a, /* " + Self.notes + " it's */ b FROM orders WHERE st"
        let context = try #require(analyzedWindow(text, on: "PostgreSQL"))
        #expect(!context.isInsideString)
        #expect(context.clauseType == .where_)
        #expect(context.prefix == "st")
    }

    @Test(
        "Nothing completes right after a statement break with nothing behind it",
        arguments: [
            ("SELECT 1;", 9, true),
            ("SELECT 1\n", 9, true),
            ("SELECT 1;\n  ", 9, true),
            ("SELECT 1; SELECT", 9, false),
            ("SELECT", 6, false),
            ("", 0, false)
        ]
    )
    func statementBreak(text: String, offset: Int, suppressed: Bool) {
        #expect(SQLCompletionTriggerPolicy.suppressesAfterStatementBreak(in: text as NSString, at: offset) == suppressed)
    }

    static let locatedCutCases: [LocatedCutCase] = [
        LocatedCutCase(testDescription: "short text", text: "SELECT * FROM or", engine: "ANSI"),
        LocatedCutCase(testDescription: "long statement", text: String(repeating: "x", count: 12_000), engine: "ANSI"),
        LocatedCutCase(
            testDescription: "last of many statements",
            text: "SELECT 1;\n" + String(repeating: "SELECT 2;\n", count: 2_000) + "SELECT * FROM or",
            engine: "ANSI"
        ),
        LocatedCutCase(
            testDescription: "token boundary",
            text: "SELECT " + String(repeating: "alpha, ", count: 1_000) + "o FROM t WHERE x",
            engine: "ANSI"
        ),
        LocatedCutCase(
            testDescription: "quoted name",
            text: "SELECT * FROM \"" + String(repeating: "n", count: 6_000) + " Det",
            engine: "PostgreSQL"
        ),
        LocatedCutCase(testDescription: "long block comment", text: "/*\n" + notes + "SELECT * FROM or", engine: "PostgreSQL"),
        LocatedCutCase(
            testDescription: "dollar body",
            text: "CREATE FUNCTION f() RETURNS void AS $$\nBEGIN\n" + body + "  SELECT * FROM or",
            engine: "PostgreSQL"
        ),
        LocatedCutCase(testDescription: "open string", text: "INSERT INTO notes VALUES ('" + notes + "SELECT * FROM or", engine: "MySQL"),
        LocatedCutCase(
            testDescription: "code after a dollar body",
            text: "CREATE FUNCTION f() RETURNS void AS $$\nBEGIN\n" + body + "END\n$$ LANGUAGE plpgsql;\nSELECT * FROM or",
            engine: "PostgreSQL"
        ),
        LocatedCutCase(
            testDescription: "code after a closed string",
            text: "INSERT INTO notes VALUES ('" + notes + "');\nSELECT * FROM or",
            engine: "MySQL"
        ),
        LocatedCutCase(
            testDescription: "comment across the cut",
            text: "SELECT a, /* " + notes + " it's */ b FROM orders WHERE st",
            engine: "PostgreSQL"
        ),
        LocatedCutCase(
            testDescription: "MySQL delimiter",
            text: "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END //\nDELIMITER ;\nSELECT * FROM or",
            engine: "MySQL"
        )
    ]

    @Test("A cut from the located statement equals a cut from the whole text", arguments: SQLCompletionWindowTests.locatedCutCases)
    func cutFromALocatedStatementEqualsTheWholeTextCut(_ example: LocatedCutCase) {
        let text = example.text as NSString
        let grammar = SQLLexicalGrammar.engine(example.engine)
        let carets = Set([0, text.length / 3, text.length / 2, text.length - 1, text.length].filter { $0 >= 0 })
        for caret in carets.sorted() {
            let located = SQLStatementScanner.locatedStatementAtCursor(
                in: example.text, cursorPosition: caret, grammar: grammar
            )
            let whole = SQLCompletionWindow.cut(text, around: caret, grammar: grammar)
            let fromStatement = SQLCompletionWindow.cut(text, around: caret, statement: located.range, grammar: grammar)
            #expect(fromStatement?.text == whole?.text, "caret \(caret)")
            #expect(fromStatement?.start == whole?.start, "caret \(caret)")
        }
    }

    @Test("A cut from the located statement near the end of a long script reads only that statement and the radius")
    func cutFromALocatedStatementReadsOnlyItsStatement() {
        let script = String(repeating: "SELECT id, name FROM users WHERE id = 1;\n", count: 10_000) + "SELECT * FROM or"
        let text = CountingString(script)
        let caret = text.length
        let located = SQLStatementScanner.locatedStatementAtCursor(in: script, cursorPosition: caret, grammar: .ansi)

        let window = SQLCompletionWindow.cut(text, around: caret, statement: located.range, grammar: .ansi)

        #expect(window?.text == "\nSELECT * FROM or")
        #expect(text.unitsRead <= located.range.length + SQLCompletionWindow.radius)
    }
}
