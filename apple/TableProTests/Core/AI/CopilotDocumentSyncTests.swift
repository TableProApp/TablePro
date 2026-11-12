import AppKit
import Foundation
@testable import TablePro
import TableProEditorKit
import TableProTestSupport
import TableProTextEngine
import Testing
import TextStory

@MainActor
private final class RecordingCopilotServer: CopilotDocumentServer {
    enum Message {
        case open(LSPTextDocumentItem)
        case change(LSPDidChangeParams)
        case focus(String)
        case close(String)
    }

    var generation = 1
    var hasClient = true
    private(set) var messages: [Message] = []

    var changes: [LSPDidChangeParams] {
        messages.compactMap { message in
            guard case .change(let params) = message else { return nil }
            return params
        }
    }

    func didOpen(_ document: LSPTextDocumentItem) async {
        messages.append(.open(document))
    }

    func didChange(_ change: LSPDidChangeParams) async {
        messages.append(.change(change))
    }

    func didFocus(uri: String) async {
        messages.append(.focus(uri))
    }

    func didClose(uri: String) async {
        messages.append(.close(uri))
    }
}

@MainActor
private final class TabSelection {
    var id = UUID()
}

@MainActor
private final class SchemaSelection {
    var provider: SQLSchemaProvider
    var budget: Int

    init(provider: SQLSchemaProvider, budget: Int) {
        self.provider = provider
        self.budget = budget
    }

    var source: CopilotPreambleBuilder.Source {
        CopilotPreambleBuilder.Source(
            schemaProvider: provider,
            databaseName: "shop",
            databaseType: .mysql,
            grammar: DatabaseType.mysql.lexicalGrammar,
            budget: budget
        )
    }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

// The server's document model (vscode-languageserver-textdocument): CR, LF and CR LF end a line, and a position past
// a line's content is clamped to before its line break.
private struct LSPDocumentModel {
    private var units: [UInt16]

    init(_ text: String) {
        units = Array(text.utf16)
    }

    var text: String {
        String(decoding: units, as: UTF16.self)
    }

    mutating func apply(_ change: LSPTextDocumentContentChangeEvent) {
        let replacement = Array(change.text.utf16)
        guard let range = change.range else {
            units = replacement
            return
        }
        let start = offset(at: range.start)
        let end = max(start, offset(at: range.end))
        units.replaceSubrange(start..<end, with: replacement)
    }

    private func offset(at position: LSPPosition) -> Int {
        let lineStarts = lineStarts()
        guard position.line < lineStarts.count else { return units.count }
        guard position.line >= 0 else { return 0 }
        let lineStart = lineStarts[position.line]
        guard position.character > 0 else { return lineStart }
        let nextLineStart = position.line + 1 < lineStarts.count ? lineStarts[position.line + 1] : units.count
        var offset = min(lineStart + position.character, nextLineStart)
        while offset > lineStart, units[offset - 1] == 0x0D || units[offset - 1] == 0x0A {
            offset -= 1
        }
        return offset
    }

    private func lineStarts() -> [Int] {
        var starts = [0]
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 0x0D || unit == 0x0A {
                if unit == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A {
                    index += 1
                }
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }
}

@MainActor
struct CopilotDocumentSyncTests {
    @MainActor
    private struct Harness {
        let controller: TextViewController
        let server: RecordingCopilotServer
        let sync: CopilotDocumentSync
        let tab: TabSelection
        let schema: SchemaSelection

        var textView: TextView { controller.textView }
        var uri: String { sync.documentURI(for: tab.id) }
        var expectedText: String { sync.preambleBuilder.preamble + controller.textView.string }

        func replayed(uri: String? = nil) -> String? {
            CopilotDocumentSyncTests.replayedText(of: server.messages, uri: uri ?? self.uri)
        }
    }

    @Test("random edits, typing filter edits and a multi-range replace replay to the editor's text as range changes")
    func incrementalEditsReplayToTheEditorText() async throws {
        let harness = await Self.makeHarness(text: "SELECT id, name\nFROM table_0\nWHERE id = 1;\n")
        var generator = SeededGenerator(seed: 0x5EED)
        let snippets = ["x", "SELECT ", "\n", "a\nb", "é", "😀", "  ", "\n\n", "(", "'", ";\n"]

        for step in 0..<120 {
            let text = harness.textView.string as NSString
            let location = Self.boundary(generator.index(below: text.length + 1), in: text)
            let end = Self.boundary(min(text.length, location + 1 + generator.index(below: 8)), in: text)
            let snippet = snippets[generator.index(below: snippets.count)]
            switch generator.index(below: 3) {
            case 0:
                harness.textView.replaceCharacters(in: NSRange(location: location, length: 0), with: snippet)
            case 1:
                harness.textView.replaceCharacters(in: NSRange(location: location, length: end - location), with: "")
            default:
                harness.textView.replaceCharacters(in: NSRange(location: location, length: end - location), with: snippet)
            }
            if step.isMultiple(of: 10) {
                await harness.sync.flush()
            }
        }

        let text = harness.textView.string as NSString
        harness.textView.replaceCharacters([
            TextReplacement(range: NSRange(location: 0, length: 0), string: "-- head\n"),
            TextReplacement(range: NSRange(location: Self.boundary(text.length / 2, in: text), length: 0), string: "mid\n"),
            TextReplacement(range: NSRange(location: text.length, length: 0), string: "\n-- tail")
        ])
        harness.textView.applyMutation(
            TextMutation(string: "/* filter */\n", range: NSRange(location: 0, length: 0), limit: harness.textView.textStorage.length)
        )
        await harness.sync.flush()

        let sent = harness.server.changes
        try #require(!sent.isEmpty)
        #expect(sent.allSatisfy { params in params.contentChanges.allSatisfy { $0.range != nil } })
        let versions = sent.map { $0.textDocument.version }
        #expect(versions == Array(1...sent.count))
        #expect(harness.replayed() == harness.expectedText)
    }

    @Test("a keystroke in a 130,000 unit script with a 300-table preamble sends under 1 KB")
    func keystrokePayloadStaysSmall() async throws {
        let document = Self.script(units: 130_000)
        let harness = await Self.makeHarness(text: document, tableCount: 300)
        let fullText = LSPDidChangeParams(
            textDocument: LSPVersionedTextDocumentIdentifier(uri: harness.uri, version: 1),
            contentChanges: [LSPTextDocumentContentChangeEvent(text: harness.sync.preambleBuilder.prependToText(document))]
        )
        let fullTextBytes = try JSONEncoder().encode(fullText).count

        harness.textView.replaceCharacters(in: NSRange(location: 65_000, length: 0), with: "x")
        await harness.sync.flush()

        let keystroke = try #require(harness.server.changes.last)
        let keystrokeBytes = try JSONEncoder().encode(keystroke).count
        #expect(keystroke.contentChanges.first?.range != nil)
        #expect(keystrokeBytes < 1_024)
        #expect(fullTextBytes > 200_000)
        #expect(harness.replayed() == harness.expectedText)
    }

    @Test("typing in a CR LF script stays incremental; an edit inside a CR LF sends the full text until the lines agree again")
    func editNextToCarriageReturnSendsFullText() async throws {
        let harness = await Self.makeHarness(text: "SELECT id\r\nFROM table_0\r\nWHERE id = 1\r\n")

        harness.textView.replaceCharacters(in: NSRange(location: 13, length: 0), with: "x")
        await harness.sync.flush()
        let typed = try #require(harness.server.changes.last)
        #expect(typed.contentChanges.allSatisfy { $0.range != nil })
        #expect(harness.replayed() == harness.expectedText)

        let lineFeed = (harness.textView.string as NSString).range(of: "\n", options: .literal).location
        harness.textView.replaceCharacters(in: NSRange(location: lineFeed, length: 0), with: "y")
        await harness.sync.flush()
        let split = try #require(harness.server.changes.last)
        #expect(split.contentChanges.count == 1)
        #expect(split.contentChanges.first?.range == nil)
        #expect(harness.replayed() == harness.expectedText)

        harness.textView.replaceCharacters(in: NSRange(location: harness.textView.textStorage.length, length: 0), with: "LIMIT 1")
        await harness.sync.flush()
        let later = try #require(harness.server.changes.last)
        #expect(later.contentChanges.first?.range == nil)
        #expect(harness.replayed() == harness.expectedText)

        harness.textView.replaceCharacters(in: NSRange(location: lineFeed, length: 1), with: "")
        await harness.sync.flush()
        let rejoined = try #require(harness.server.changes.last)
        #expect(rejoined.contentChanges.first?.range == nil)

        harness.textView.replaceCharacters(in: NSRange(location: harness.textView.textStorage.length, length: 0), with: ";")
        await harness.sync.flush()
        let resumed = try #require(harness.server.changes.last)
        #expect(resumed.contentChanges.allSatisfy { $0.range != nil })
        #expect(harness.replayed() == harness.expectedText)
    }

    @Test("switching tabs sends nothing; the first edit or request there closes the old document and opens the new one")
    func tabSwitchSendsNothingUntilTheTabIsUsed() async {
        let harness = await Self.makeHarness(text: "SELECT 1;\n")
        let firstURI = harness.uri
        let before = harness.server.messages.count

        harness.tab.id = UUID()
        harness.controller.setText("SELECT name FROM table_1;\n")
        harness.sync.textViewDidReplaceDocument()
        #expect(harness.sync.currentDocumentInfo()?.uri == nil)

        harness.textView.replaceCharacters(in: NSRange(location: 7, length: 0), with: "id, ")
        await harness.sync.flush()
        let secondURI = harness.uri
        #expect(secondURI != firstURI)
        #expect(Self.summary(Array(harness.server.messages.dropFirst(before))) == [
            "close \(firstURI)", "open \(secondURI)", "focus \(secondURI)"
        ])
        #expect(harness.sync.currentDocumentInfo()?.uri == secondURI)
        #expect(harness.replayed(uri: secondURI) == harness.expectedText)
        #expect(harness.replayed(uri: firstURI) == nil)

        let switched = harness.server.messages.count
        harness.tab.id = UUID()
        harness.controller.setText("SELECT 3;\n")
        harness.sync.textViewDidReplaceDocument()
        await harness.sync.flush()
        #expect(Self.summary(Array(harness.server.messages.dropFirst(switched))) == [
            "close \(secondURI)", "open \(harness.uri)", "focus \(harness.uri)"
        ])
        #expect(harness.replayed() == harness.expectedText)
    }

    @Test("a request whose statement names an undescribed table puts it in the preamble and resends the full text once")
    func requestAddsTheStatementsTableToThePreamble() async throws {
        let fetches = FetchCounter()
        let harness = await Self.makeHarness(text: "SELECT 1;\n", tableCount: 2_000, maxTables: 20, fetches: fetches)
        #expect(!harness.sync.preambleBuilder.preamble.contains("-- table_1500("))
        harness.textView.replaceCharacters(in: NSRange(location: 0, length: 9), with: "SELECT * FROM table_1500;")
        await harness.sync.flush()
        let before = harness.server.messages.count
        let fetchesBefore = fetches.count

        harness.sync.refreshPreamble(forStatementAt: 10, in: harness.textView.string)
        try await waitUntil { harness.sync.preambleBuilder.preamble.contains("-- table_1500(") }
        await harness.sync.flush()

        #expect(fetches.count - fetchesBefore <= 20)
        let tail = Array(harness.server.messages.dropFirst(before))
        #expect(Self.summary(tail) == ["change \(harness.uri)"])
        let resent = try #require(harness.server.changes.last)
        #expect(resent.contentChanges.count == 1)
        #expect(resent.contentChanges.first?.range == nil)
        #expect(resent.contentChanges.first?.text.contains("-- table_1500(") == true)
        #expect(harness.replayed() == harness.expectedText)

        let settled = harness.server.messages.count
        let described = await harness.sync.preambleBuilder.rebuiltPreamble(
            forStatementAt: 10,
            in: harness.textView.string,
            from: harness.schema.source
        )
        #expect(described?.preamble == nil)
        await harness.sync.flush()
        #expect(harness.server.messages.count == settled)
    }

    @Test("an editor that had no schema when Copilot started gets the schema header on its first request")
    func requestBuildsThePreambleAnEditorStartedWithout() async throws {
        let harness = await Self.makeHarness(text: "SELECT * FROM table_1;\n", buildsPreamble: false)
        #expect(harness.sync.preambleBuilder.preamble.isEmpty)
        let before = harness.server.messages.count

        harness.sync.refreshPreamble(forStatementAt: 10, in: harness.textView.string)
        try await waitUntil { harness.sync.preambleBuilder.preamble.contains("-- table_1(") }
        await harness.sync.flush()

        #expect(harness.server.messages.count == before + 1)
        let resent = try #require(harness.server.changes.last)
        #expect(resent.contentChanges.first?.range == nil)
        #expect(resent.contentChanges.first?.text.hasPrefix("-- Database: shop\n") == true)
        #expect(harness.replayed() == harness.expectedText)
    }

    @Test("after the tab moves to another database, a request describes that database's table of the same name")
    func requestFollowsTheTabsSchemaProvider() async throws {
        let sales = await Self.makeProvider(
            tables: [TestFixtures.makeTableInfo(name: "orders")],
            columns: [TestFixtures.makeColumnInfo(name: "amount", dataType: "DECIMAL")]
        )
        let staff = await Self.makeProvider(
            tables: [TestFixtures.makeTableInfo(name: "orders")],
            columns: [TestFixtures.makeColumnInfo(name: "salary", dataType: "INT")]
        )
        let harness = await Self.makeHarness(text: "SELECT * FROM orders;\n", provider: sales)
        #expect(harness.sync.preambleBuilder.preamble.contains("-- orders(amount DECIMAL PK NOT NULL)"))
        let before = harness.server.messages.count

        harness.schema.provider = staff
        harness.sync.refreshPreamble(forStatementAt: 10, in: harness.textView.string)
        try await waitUntil { harness.sync.preambleBuilder.preamble.contains("salary") }
        await harness.sync.flush()

        let resent = try #require(harness.server.changes.last)
        #expect(harness.server.messages.count == before + 1)
        #expect(resent.contentChanges.first?.range == nil)
        let text = try #require(resent.contentChanges.first?.text)
        #expect(text.contains("-- orders(salary INT PK NOT NULL)"))
        #expect(!text.contains("amount"))
        #expect(harness.replayed() == harness.expectedText)
    }

    @Test("a lower Max schema tables applies on the next request")
    func lowerBudgetAppliesOnTheNextRequest() async throws {
        let harness = await Self.makeHarness(text: "SELECT 1;\n", tableCount: 10)
        #expect(harness.sync.preambleBuilder.preamble.contains("-- table_9("))

        harness.schema.budget = 3
        harness.sync.refreshPreamble(forStatementAt: 3, in: harness.textView.string)
        try await waitUntil { !harness.sync.preambleBuilder.preamble.contains("-- table_9(") }
        await harness.sync.flush()

        let text = try #require(harness.server.changes.last?.contentChanges.first?.text)
        #expect(text.contains("-- … and 7 more tables"))
        #expect(harness.replayed() == harness.expectedText)
    }

    @Test("a tab switch that keeps the same text moves the next edit to the new tab's document")
    func tabSwitchWithTheSameTextMovesTheNextEdit() async {
        let harness = await Self.makeHarness(text: "SELECT 1;\n")
        let firstURI = harness.uri
        let before = harness.server.messages.count

        harness.tab.id = UUID()
        harness.textView.replaceCharacters(in: NSRange(location: 8, length: 0), with: ", 2")
        await harness.sync.flush()

        #expect(Self.summary(Array(harness.server.messages.dropFirst(before))) == [
            "close \(firstURI)", "open \(harness.uri)", "focus \(harness.uri)"
        ])
        #expect(harness.sync.currentDocumentInfo()?.uri == harness.uri)
        #expect(harness.replayed() == harness.expectedText)
    }

    @Test("after the server restarts, the next edit or request reopens the document with its full text")
    func serverRestartReopensTheDocument() async {
        let harness = await Self.makeHarness(text: "SELECT 1;\n")
        let before = harness.server.messages.count

        harness.server.hasClient = false
        harness.server.generation += 1
        harness.textView.replaceCharacters(in: NSRange(location: 8, length: 0), with: ", 2")
        await harness.sync.flush()
        #expect(harness.server.messages.count == before)
        #expect(harness.sync.currentDocumentInfo()?.uri == nil)

        harness.server.hasClient = true
        harness.server.generation += 1
        harness.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "-- again\n")
        await harness.sync.flush()
        #expect(Self.summary(Array(harness.server.messages.dropFirst(before))) == ["open \(harness.uri)", "focus \(harness.uri)"])
        #expect(harness.sync.currentDocumentInfo()?.version == 0)
        #expect(harness.replayed() == harness.expectedText)

        let reopened = harness.server.messages.count
        harness.server.generation += 1
        await harness.sync.flush()
        #expect(Self.summary(Array(harness.server.messages.dropFirst(reopened))) == ["open \(harness.uri)", "focus \(harness.uri)"])
        #expect(harness.replayed() == harness.expectedText)
    }

    @Test("past the length limit nothing is sent, and back under it the full text is")
    func overTheLengthLimitResyncsOnceUnder() async throws {
        let harness = await Self.makeHarness(text: "SELECT 1;", lengthLimit: 20)
        let before = harness.server.messages.count

        harness.textView.replaceCharacters(in: NSRange(location: 9, length: 0), with: " -- a long comment")
        await harness.sync.flush()
        #expect(harness.server.messages.count == before)
        #expect(harness.sync.currentDocumentInfo()?.uri == nil)

        harness.textView.replaceCharacters(in: NSRange(location: 9, length: 18), with: "")
        await harness.sync.flush()
        let resync = try #require(harness.server.changes.last)
        #expect(resync.contentChanges.count == 1)
        #expect(resync.contentChanges.first?.range == nil)
        #expect(harness.replayed() == harness.expectedText)
    }

    // MARK: - Helpers

    private static func makeHarness(
        text: String,
        tableCount: Int = 3,
        maxTables: Int? = nil,
        lengthLimit: Int = 2_000_000,
        fetches: FetchCounter? = nil,
        provider given: SQLSchemaProvider? = nil,
        buildsPreamble: Bool = true
    ) async -> Harness {
        let server = RecordingCopilotServer()
        let sync = CopilotDocumentSync(server: server, lengthLimit: lengthLimit)
        let provider: SQLSchemaProvider
        if let given {
            provider = given
        } else {
            provider = await makeProvider(
                tables: (0..<tableCount).map { TestFixtures.makeTableInfo(name: "table_\($0)") },
                columns: (0..<8).map { TestFixtures.makeColumnInfo(name: "column_\($0)", dataType: "VARCHAR(255)") },
                fetches: fetches
            )
        }
        let schema = SchemaSelection(provider: provider, budget: maxTables ?? tableCount)
        if buildsPreamble {
            await sync.preambleBuilder.buildPreamble(
                schemaProvider: provider,
                databaseName: "shop",
                databaseType: .mysql,
                maxTables: schema.budget
            )
        }
        let controller = EditorControllerFixture.make(string: text)
        let tab = TabSelection()
        sync.attach(
            to: controller.textView,
            tabID: { tab.id },
            isAllowed: { true },
            schemaSource: { schema.source }
        )
        await sync.flush()
        return Harness(controller: controller, server: server, sync: sync, tab: tab, schema: schema)
    }

    private static func makeProvider(
        tables: [TableInfo],
        columns: [ColumnInfo],
        fetches: FetchCounter? = nil
    ) async -> SQLSchemaProvider {
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { _, _ in
                fetches?.increment()
                return columns
            },
            fetchAllColumns: { [:] }
        )
        let provider = SQLSchemaProvider(metadataSource: source)
        await provider.resetForDatabase(
            "shop",
            tables: tables,
            driver: MockDatabaseDriver(),
            connection: TestFixtures.makeConnection()
        )
        await provider.waitForEagerColumnLoad()
        return provider
    }

    private static func script(units: Int) -> String {
        let block = "CREATE TABLE t (\n  id INT,\n  name TEXT\n);\nSELECT id, name\n  FROM t\n WHERE id IN (\n   1, 2, 3\n );\n"
        return String(repeating: block, count: units / (block as NSString).length + 1)
    }

    private static func boundary(_ offset: Int, in text: NSString) -> Int {
        guard offset > 0, offset < text.length else { return offset }
        return text.rangeOfComposedCharacterSequence(at: offset).location
    }

    private static func summary(_ messages: [RecordingCopilotServer.Message]) -> [String] {
        messages.map { message -> String in
            switch message {
            case .open(let document): "open \(document.uri)"
            case .change(let params): "change \(params.textDocument.uri)"
            case .focus(let uri): "focus \(uri)"
            case .close(let uri): "close \(uri)"
            }
        }
    }

    private static func replayedText(of messages: [RecordingCopilotServer.Message], uri: String) -> String? {
        var model: LSPDocumentModel?
        for message in messages {
            switch message {
            case .open(let document) where document.uri == uri:
                model = LSPDocumentModel(document.text)
            case .change(let params) where params.textDocument.uri == uri:
                for change in params.contentChanges {
                    model?.apply(change)
                }
            case .close(let closed) where closed == uri:
                model = nil
            default:
                break
            }
        }
        return model?.text
    }
}
