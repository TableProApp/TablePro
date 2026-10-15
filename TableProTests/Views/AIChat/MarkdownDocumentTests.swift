//
//  MarkdownDocumentTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

struct MarkdownDocumentTests {
    private func parse(_ source: String) -> [MarkdownBlock] {
        MarkdownDocumentParser.parse(source).blocks
    }

    private func plain(_ text: AttributedString) -> String {
        String(text.characters)
    }

    private func paragraphText(_ block: MarkdownBlock?) -> String? {
        guard case .paragraph(let text)? = block?.kind else { return nil }
        return plain(text)
    }

    private func code(_ block: MarkdownBlock?) -> (code: String, language: String?)? {
        guard case .codeBlock(let code, let language)? = block?.kind else { return nil }
        return (code, language)
    }

    private func list(_ block: MarkdownBlock?) -> MarkdownList? {
        guard case .list(let list)? = block?.kind else { return nil }
        return list
    }

    private func table(_ block: MarkdownBlock?) -> MarkdownTable? {
        guard case .table(let table)? = block?.kind else { return nil }
        return table
    }

    // MARK: - Code

    @Test("A closed fence keeps its code and language")
    func closedFence() {
        let blocks = parse("```sql\nSELECT 1\n```")
        #expect(blocks.count == 1)
        #expect(code(blocks.first)?.code == "SELECT 1")
        #expect(code(blocks.first)?.language == "sql")
    }

    @Test("An unclosed fence is code up to the end while it streams")
    func unclosedFence() {
        let blocks = parse("```sql\nSELECT * FROM users\nWHERE id = 1")
        #expect(blocks.count == 1)
        #expect(code(blocks.first)?.code == "SELECT * FROM users\nWHERE id = 1")
        #expect(code(blocks.first)?.language == "sql")
    }

    @Test("A fence with no code yet draws nothing until its first line arrives")
    func openerOnly() {
        #expect(parse("```sql").isEmpty)
        #expect(code(parse("```sql\nS").first)?.code == "S")
    }

    @Test("A tilde fence streams like a backtick one")
    func unclosedTildeFence() {
        let blocks = parse("~~~javascript\ndb.users.find({})")
        #expect(code(blocks.first)?.code == "db.users.find({})")
        #expect(code(blocks.first)?.language == "javascript")
    }

    @Test("A fence with no info string has no language")
    func fenceWithoutLanguage() {
        #expect(code(parse("```\nSELECT 1\n```").first)?.language == nil)
    }

    @Test("A paragraph before an open fence stays its own block")
    func paragraphThenOpenFence() {
        let blocks = parse("Here is the query:\n\n```sql\nSELECT 1")
        #expect(blocks.count == 2)
        #expect(paragraphText(blocks.first) == "Here is the query:")
        #expect(code(blocks.last)?.code == "SELECT 1")
    }

    @Test("A longer closing fence closes, and a shorter inner one does not")
    func fenceLengths() {
        #expect(code(parse("````sql\nSELECT 1\n````").first)?.code == "SELECT 1")
        let inner = parse("````\n```\nstill code\n````")
        #expect(inner.count == 1)
        #expect(code(inner.first)?.code == "```\nstill code")
    }

    @Test("A closed block before a fence still streaming keeps its code")
    func closedThenOpen() {
        let blocks = parse("```sql\nSELECT 1\n```\n\nThen run:\n\n```sql\nSELECT 2")
        #expect(code(blocks.first)?.code == "SELECT 1")
        #expect(code(blocks.last)?.code == "SELECT 2")
    }

    // MARK: - Lists

    /// The shape of the reply in the report: a fence and a note indented under item 4, then item 5.
    @Test("Content indented under a list item belongs to it, with the indentation removed")
    func listItemHoldsIndentedContent() throws {
        let source = """
        3. **Quyền**: xác nhận có quyền DELETE.
        4. **Chỉ xoá chữ ký của user hiện tại**: dùng:

           ```sql
           DELETE l FROM `user_signature_audit_logs` l
           WHERE s.user_id IN ('<uuid1>', '<uuid2>');
           ```

           (user_signatures.user_id là VARCHAR(191).)

        5. **Bảng chữ ký khác không bị ảnh hưởng**.
        """
        let blocks = parse(source)
        #expect(blocks.count == 1)
        let list = try #require(list(blocks.first))
        #expect(list.start == 3)
        #expect(list.items.count == 3)

        let item = list.items[1]
        #expect(item.blocks.count == 3)
        #expect(paragraphText(item.blocks.first) == "Chỉ xoá chữ ký của user hiện tại: dùng:")
        #expect(code(item.blocks[1])?.code == "DELETE l FROM `user_signature_audit_logs` l\nWHERE s.user_id IN ('<uuid1>', '<uuid2>');")
        #expect(paragraphText(item.blocks[2]) == "(user_signatures.user_id là VARCHAR(191).)")
    }

    @Test("A nested list is a block of its item")
    func nestedList() throws {
        let blocks = parse("- outer\n  - inner a\n  - inner b\n- second")
        let outer = try #require(list(blocks.first))
        #expect(outer.start == nil)
        #expect(outer.items.count == 2)
        let inner = try #require(list(outer.items[0].blocks.last))
        #expect(inner.items.count == 2)
    }

    @Test("A loose list numbered 1. 1. 1. is one list counting up")
    func looseListIsOneList() throws {
        let blocks = parse("1. one\n\n1. two\n\n1. three")
        #expect(blocks.count == 1)
        let list = try #require(list(blocks.first))
        #expect(list.start == 1)
        #expect(list.items.count == 3)
    }

    @Test("A heading, an ordered list and a bulleted list are three blocks")
    func headerAndLists() throws {
        let blocks = parse("## Plan\n\n1. Index the foreign key\n2. Rewrite the join\n- also check nulls")
        #expect(blocks.count == 3)
        guard case .header(let level, let text)? = blocks.first?.kind else {
            Issue.record("Expected a heading")
            return
        }
        #expect(level == 2)
        #expect(plain(text) == "Plan")
        #expect(try #require(list(blocks[1])).items.count == 2)
        #expect(try #require(list(blocks[2])).start == nil)
    }

    // MARK: - Tables

    @Test("A table keeps its header, alignments and rows")
    func completeTable() throws {
        let table = try #require(table(parse("| name | age |\n| :--- | --: |\n| Ada  | 36  |").first))
        #expect(table.header.map(plain) == ["name", "age"])
        #expect(table.alignments == [.left, .right])
        #expect(table.rows.map { $0.map(plain) } == [["Ada", "36"]])
    }

    @Test("A table header without its separator row is a paragraph")
    func incompleteTable() {
        #expect(paragraphText(parse("| name | age |").first) == "| name | age |")
    }

    @Test("A table right after a paragraph is a table")
    func tableAfterParagraph() throws {
        let blocks = parse("Results:\n| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(blocks.count == 2)
        #expect(paragraphText(blocks.first) == "Results:")
        #expect(try #require(table(blocks.last)).rows.count == 1)
    }

    @Test("Rows without outer pipes are table rows")
    func rowsWithoutOuterPipes() throws {
        let table = try #require(table(parse("a | b\n--|--\n1 | 2\n3 | 4").first))
        #expect(table.rows.map { $0.map(plain) } == [["1", "2"], ["3", "4"]])
    }

    @Test("An empty cell keeps the cells after it in their columns")
    func emptyCell() throws {
        let table = try #require(table(parse("| a | b | c |\n|---|---|---|\n| 1 |  | 3 |").first))
        #expect(table.rows.map { $0.map(plain) } == [["1", "", "3"]])
    }

    // MARK: - Inline

    @Test("A line break inside a paragraph stays a line break")
    func softBreakIsLineBreak() {
        #expect(paragraphText(parse("line one\nline two").first) == "line one\nline two")
    }

    @Test("Inline styles survive the block parse")
    func inlineStyles() throws {
        guard case .paragraph(let text)? = parse("a **bold** and `code`").first?.kind else {
            Issue.record("Expected a paragraph")
            return
        }
        let bold = try #require(text.range(of: "bold"))
        #expect(text[bold].inlinePresentationIntent == .stronglyEmphasized)
        let code = try #require(text.range(of: "code"))
        #expect(text[code].inlinePresentationIntent == .code)
        #expect(text.presentationIntent == nil)
    }

    @Test("Raw HTML shows as its text")
    func rawHTML() {
        #expect(paragraphText(parse("<div>html</div>").first)?.contains("<div>html</div>") == true)
    }

    @Test("Empty text has no blocks")
    func emptySource() {
        #expect(parse("").isEmpty)
    }

    // MARK: - Streaming

    @Test("A dangling bold run reads as bold while the reply streams")
    func streamingRepairsDanglingBold() throws {
        let blocks = MarkdownDocumentParser.parseStreaming("this is **bold").blocks
        guard case .paragraph(let text)? = blocks.first?.kind else {
            Issue.record("Expected a paragraph")
            return
        }
        #expect(plain(text) == "this is bold")
        let bold = try #require(text.range(of: "bold"))
        #expect(text[bold].inlinePresentationIntent == .stronglyEmphasized)
    }

    @Test("Code still streaming is left exactly as written")
    func streamingLeavesCodeAlone() {
        let blocks = MarkdownDocumentParser.parseStreaming("```sql\nSELECT **x").blocks
        #expect(code(blocks.first)?.code == "SELECT **x")
    }

    @Test("A row's document ends on the newest text it was given while the reply streams")
    @MainActor
    func streamingModelEndsOnNewestText() async throws {
        let model = MarkdownDocumentModel(source: "first", isStreaming: true)
        model.update(source: "first second", isStreaming: true)
        model.update(source: "first second third", isStreaming: true)
        try await waitUntil {
            paragraphText(model.document.blocks.first) == "first second third"
        }
        #expect(model.isSettled == false)
    }

    @Test("A finished reply keeps its last document until the final parse lands, then caches it")
    @MainActor
    func finishedReplySettlesAwayFromTheMainActor() async throws {
        let source = "Reply \(UUID().uuidString) with **bold** text"
        let model = MarkdownDocumentModel(source: String(source.dropLast(5)), isStreaming: true)
        model.update(source: source, isStreaming: false)
        #expect(model.isSettled == false)
        try await waitUntil { model.isSettled }
        #expect(model.document == MarkdownDocumentParser.parse(source))
        #expect(MarkdownDocumentCache.shared.cachedDocument(for: source) == model.document)
    }

    @Test("Settled text already parsed is shown on the row's first frame")
    @MainActor
    func cachedTextIsShownAtOnce() {
        let source = "Cached \(UUID().uuidString)"
        _ = MarkdownDocumentCache.shared.document(for: source)
        let model = MarkdownDocumentModel(source: source, isStreaming: false)
        #expect(model.isSettled)
        #expect(paragraphText(model.document.blocks.first) == source)
    }

    @Test("The settled cache returns what a parse returns")
    func settledCacheMatchesParse() async {
        let source = "# Title\n\n- a\n- b"
        await MarkdownDocumentCache.shared.prewarm([source])
        #expect(MarkdownDocumentCache.shared.document(for: source) == MarkdownDocumentParser.parse(source))
    }
}
