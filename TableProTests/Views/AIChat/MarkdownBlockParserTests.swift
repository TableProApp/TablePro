//
//  MarkdownBlockParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MarkdownBlockParser")
struct MarkdownBlockParserTests {
    @Test("Closed fenced code block is marked closed")
    func closedFence() {
        let source = """
        ```sql
        SELECT 1
        ```
        """
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 1)
        guard case .codeBlock(let code, let language, let isClosed) = blocks[0].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(code == "SELECT 1")
        #expect(language == "sql")
        #expect(isClosed == true)
    }

    @Test("Unclosed fenced code block stays a code block while streaming")
    func unclosedFence() {
        let source = """
        ```sql
        SELECT * FROM users
        WHERE id = 1
        """
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 1)
        guard case .codeBlock(let code, let language, let isClosed) = blocks[0].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(code.contains("SELECT * FROM users"))
        #expect(code.contains("WHERE id = 1"))
        #expect(language == "sql")
        #expect(isClosed == false)
    }

    @Test("Unclosed fence with only opener yields empty open code block")
    func unclosedFenceOpenerOnly() {
        let blocks = MarkdownBlockParser.parse("```sql")
        #expect(blocks.count == 1)
        guard case .codeBlock(let code, let language, let isClosed) = blocks[0].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(code.isEmpty)
        #expect(language == "sql")
        #expect(isClosed == false)
    }

    @Test("Tilde fences support unclosed streaming")
    func unclosedTildeFence() {
        let source = """
        ~~~javascript
        db.users.find({})
        """
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 1)
        guard case .codeBlock(let code, let language, let isClosed) = blocks[0].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(code == "db.users.find({})")
        #expect(language == "javascript")
        #expect(isClosed == false)
    }

    @Test("Paragraph before open fence remains a separate block")
    func paragraphThenOpenFence() {
        let source = """
        Here is the query:

        ```sql
        SELECT 1
        """
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 2)
        guard case .paragraph(let text) = blocks[0].kind else {
            Issue.record("Expected paragraph")
            return
        }
        #expect(text.contains("Here is the query"))
        guard case .codeBlock(let code, let language, let isClosed) = blocks[1].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(code == "SELECT 1")
        #expect(language == "sql")
        #expect(isClosed == false)
    }

    @Test("Incomplete table header without separator stays a paragraph")
    func incompleteTableAsParagraph() {
        let source = "| name | age |"
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 1)
        guard case .paragraph(let text) = blocks[0].kind else {
            Issue.record("Expected paragraph for incomplete table")
            return
        }
        #expect(text == "| name | age |")
    }

    @Test("Complete table still parses with alignments")
    func completeTable() {
        let source = """
        | name | age |
        | :--- | --: |
        | Ada  | 36  |
        """
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 1)
        guard case .table(let headers, let alignments, let rows) = blocks[0].kind else {
            Issue.record("Expected table")
            return
        }
        #expect(headers == ["name", "age"])
        #expect(alignments == [.left, .right])
        #expect(rows.count == 1)
        #expect(rows[0] == ["Ada", "36"])
    }

    @Test("Headers and lists parse during partial stream")
    func headersAndLists() {
        let source = """
        ## Plan

        1. Index the foreign key
        2. Rewrite the join
        - also check nulls
        """
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count >= 3)
        guard case .header(let level, let text) = blocks[0].kind else {
            Issue.record("Expected header")
            return
        }
        #expect(level == 2)
        #expect(text == "Plan")
        guard case .orderedList(let start, let orderedItems) = blocks[1].kind else {
            Issue.record("Expected ordered list")
            return
        }
        #expect(start == 1)
        #expect(orderedItems.count == 2)
        guard case .unorderedList(let unorderedItems) = blocks[2].kind else {
            Issue.record("Expected unordered list")
            return
        }
        #expect(unorderedItems.count == 1)
    }

    @Test("Closing a previously open fence marks the block closed")
    func fenceClosesOnFinalBackticks() {
        let open = MarkdownBlockParser.parse("```\nSELECT 1\n")
        guard case .codeBlock(_, _, let openClosed) = open[0].kind else {
            Issue.record("Expected open code block")
            return
        }
        #expect(openClosed == false)

        let closed = MarkdownBlockParser.parse("```\nSELECT 1\n```")
        guard case .codeBlock(let code, _, let isClosed) = closed[0].kind else {
            Issue.record("Expected closed code block")
            return
        }
        #expect(code == "SELECT 1")
        #expect(isClosed == true)
    }

    @Test("Longer closing fence matches CommonMark minimum length rule")
    func longerClosingFence() {
        let source = """
        ````sql
        SELECT 1
        ````
        """
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 1)
        guard case .codeBlock(let code, let language, let isClosed) = blocks[0].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(code == "SELECT 1")
        #expect(language == "sql")
        #expect(isClosed == true)
    }

    @Test("Inner shorter fence does not close a longer opener")
    func innerFenceDoesNotClose() {
        let source = """
        ````
        ```
        still code
        ````
        """
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 1)
        guard case .codeBlock(let code, _, let isClosed) = blocks[0].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(code.contains("```"))
        #expect(code.contains("still code"))
        #expect(isClosed == true)
    }

    @Test("A closed code block stays closed while a later fence streams open")
    func closedBlockThenOpenBlockDuringStream() {
        let source = """
        ```sql
        SELECT 1
        ```

        Then run:

        ```sql
        SELECT 2
        """
        let blocks = MarkdownBlockParser.parse(source)
        guard case .codeBlock(_, _, let firstClosed) = blocks.first?.kind else {
            Issue.record("Expected a leading code block")
            return
        }
        #expect(firstClosed == true)
        guard case .codeBlock(let lastCode, _, let lastClosed) = blocks.last?.kind else {
            Issue.record("Expected a trailing code block")
            return
        }
        #expect(lastCode == "SELECT 2")
        #expect(lastClosed == false)
    }
}
