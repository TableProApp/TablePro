import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

private struct UppercaseCatalog: SQLCompletionCatalog {
    let columns: [String: [String]]

    func resolveAlias(_ aliasOrName: String, in references: [TableReference]) -> String? {
        let name = aliasOrName.lowercased()
        return references.first { $0.alias?.lowercased() == name || $0.tableName.lowercased() == name }?.tableName
    }

    func columnCompletionItems(for tableName: String, schema: String?) -> [SQLCompletionItem] {
        (columns[tableName.uppercased()] ?? []).map {
            SQLCompletionItem.column($0, dataType: nil, tableName: tableName, identifier: .catalog($0))
        }
    }

    func tableCompletionItems() -> [SQLCompletionItem] { [] }
    func tableCompletionItems(inSchema schema: String) -> [SQLCompletionItem] { [] }
    func schemaCompletionItems() -> [SQLCompletionItem] { [] }
    func namespaceCompletionItems() -> [SQLCompletionItem] { [] }
    func isKnownSchema(_ name: String) -> Bool { false }
    func isKnownDatabase(_ name: String) -> Bool { false }
    func allowedValues(forColumn column: String, in references: [TableReference]) -> [String] { [] }
    func allColumnsInScope(for references: [TableReference]) -> [SQLCompletionItem] { [] }
    func allColumnsFromCachedTables() -> [SQLCompletionItem] { [] }
}

struct SQLIdentifierSpellingTests {
    private let upperFolding = SQLIdentifierRules(folding: .upper, reservedWords: ["ORDER", "SELECT"])
    private let lowerFolding = SQLIdentifierRules(folding: .lower, reservedWords: ["user"])

    private func spelling(_ policy: SQLIdentifierCase, rules: SQLIdentifierRules? = nil) -> SQLIdentifierSpelling {
        SQLIdentifierSpelling(rules: rules ?? upperFolding, policy: policy)
    }

    private func applied(
        _ items: [SQLCompletionItem],
        _ policy: SQLIdentifierCase,
        prefix: String = "",
        quoting: SQLIdentifierTokenQuoting = .none
    ) -> [SQLCompletionItem] {
        spelling(policy).applied(to: items, typedPrefix: prefix, quoting: quoting)
    }

    // MARK: - Which names may change case

    @Test("A name the engine folds back to itself takes the chosen case")
    func foldedNameIsRecased() {
        #expect(spelling(.lower).form(of: "MY_TABLE") == .bare("my_table"))
        #expect(spelling(.upper).form(of: "MY_TABLE") == .bare("MY_TABLE"))
        #expect(spelling(.lower, rules: lowerFolding).form(of: "orders") == .bare("orders"))
        #expect(spelling(.upper, rules: lowerFolding).form(of: "orders") == .bare("ORDERS"))
    }

    @Test("A name stored in mixed case or in the other case is quoted as stored")
    func unfoldedNameIsQuoted() {
        #expect(spelling(.lower).form(of: "MixedCase") == .quoted)
        #expect(spelling(.lower).form(of: "lower_only") == .quoted)
        #expect(spelling(.upper, rules: lowerFolding).form(of: "Users") == .quoted)
    }

    @Test("A reserved word, a leading digit or underscore, or a non-ASCII name stays quoted")
    func unsafeNamesAreQuoted() {
        #expect(spelling(.lower).form(of: "ORDER") == .quoted)
        #expect(spelling(.lower, rules: lowerFolding).form(of: "user") == .quoted)
        #expect(spelling(.lower).form(of: "_PRIVATE") == .quoted)
        #expect(spelling(.lower).form(of: "1ST") == .quoted)
        #expect(spelling(.lower).form(of: "CAFÉ") == .quoted)
        #expect(spelling(.lower).form(of: "MY TABLE") == .quoted)
        #expect(spelling(.lower).form(of: "") == .quoted)
    }

    @Test("As stored keeps the spelling and quotes only a name that cannot be bare")
    func asStoredKeepsSpelling() {
        #expect(spelling(.asStored).form(of: "MY_TABLE") == .bare("MY_TABLE"))
        #expect(spelling(.asStored).form(of: "MixedCase") == .quoted)
    }

    @Test("Matching the typing follows the first cased character, and as stored with none")
    func matchTypedFollowsPrefix() {
        #expect(spelling(.matchTyped).form(of: "MY_TABLE", typedPrefix: "my_t") == .bare("my_table"))
        #expect(spelling(.matchTyped).form(of: "MY_TABLE", typedPrefix: "My") == .bare("MY_TABLE"))
        #expect(spelling(.matchTyped).form(of: "MY_TABLE", typedPrefix: "_1") == .bare("MY_TABLE"))
        #expect(spelling(.matchTyped).form(of: "MY_TABLE") == .bare("MY_TABLE"))
    }

    @Test("A quote inside a quoted name is doubled")
    func quoteIsEscaped() {
        #expect(spelling(.lower).quoted("a\"b") == "\"a\"\"b\"")
    }

    // MARK: - Completion items

    @Test("A table completes in the typed case, and a mixed-case one quoted as stored")
    func tableItems() {
        let items = applied(
            [SQLCompletionItem.table("MY_TABLE"), SQLCompletionItem.table("MixedCase")],
            .matchTyped,
            prefix: "my"
        )
        #expect(items[0].label == "my_table")
        #expect(items[0].insertText == "my_table")
        #expect(items[1].label == "MixedCase")
        #expect(items[1].insertText == "\"MixedCase\"")
    }

    @Test("A qualified column keeps the qualifier as written and spells the column")
    func qualifiedColumn() {
        let item = SQLCompletionItem(
            label: "o.TOTAL",
            kind: .column,
            identifier: SQLCompletionIdentifier([.statement("o", quoted: false), .catalog("TOTAL")])
        )
        let spelled = applied([item], .lower, prefix: "to")[0]
        #expect(spelled.label == "o.total")
        #expect(spelled.insertText == "o.total")
    }

    @Test("A qualifier the statement quoted stays quoted")
    func quotedQualifier() {
        let item = SQLCompletionItem(
            label: "Orders.TOTAL",
            kind: .column,
            identifier: SQLCompletionIdentifier([.statement("Orders", quoted: true), .catalog("TOTAL")])
        )
        #expect(applied([item], .asStored)[0].insertText == "\"Orders\".TOTAL")
    }

    @Test("Inside a closed quote the stored name goes in raw; after an open one it is quoted whole")
    func typedQuote() {
        let enclosed = applied([SQLCompletionItem.table("MY_TABLE")], .lower, quoting: .enclosed)[0]
        #expect(enclosed.insertText == "MY_TABLE")
        let opened = applied([SQLCompletionItem.table("MY_TABLE")], .lower, quoting: .opened)[0]
        #expect(opened.insertText == "\"MY_TABLE\"")
    }

    @Test("Keywords and items without a catalog name are untouched")
    func otherItemsUntouched() {
        let keyword = SQLCompletionItem.keyword("SELECT")
        let literal = SQLCompletionItem(label: "'Active'", kind: .keyword)
        let items = applied([keyword, literal], .lower, prefix: "s")
        #expect(items[0].insertText == "SELECT")
        #expect(items[1].insertText == "'Active'")
    }

    @Test("A re-cased item keeps its match ranges and filter text")
    func matchStateSurvives() {
        var item = SQLCompletionItem.table("MY_TABLE")
        item.matchedRanges = [0..<4]
        let spelled = applied([item], .lower, prefix: "my_t")[0]
        #expect(spelled.matchedRanges == [0..<4])
        #expect(spelled.filterText == "my_table")
    }

    // MARK: - Statement names

    @Test("A statement name is re-cased only for an explicit case, else quoted as the caller does")
    func statementNames() {
        let quote: (String) -> String = { "\"\($0)\"" }
        #expect(spelling(.lower).statementName("MY_TABLE", quotedBy: quote) == "my_table")
        #expect(spelling(.lower).statementName("MixedCase", quotedBy: quote) == "\"MixedCase\"")
        #expect(spelling(.asStored).statementName("MY_TABLE", quotedBy: quote) == "\"MY_TABLE\"")
        #expect(spelling(.matchTyped).statementName("MY_TABLE", quotedBy: quote) == "\"MY_TABLE\"")
    }

    @Test("The token quoting is read from the analyzer's quoted name")
    func tokenQuoting() {
        #expect(SQLIdentifierTokenQuoting(nil) == .none)
        #expect(SQLIdentifierTokenQuoting(SQLQuotedName(open: 3, close: nil)) == .opened)
        #expect(SQLIdentifierTokenQuoting(SQLQuotedName(open: 3, close: 8)) == .enclosed)
    }

    // MARK: - Through the provider

    private let provider = SQLCompletionProvider(
        catalog: UppercaseCatalog(columns: ["ORDERS": ["TOTAL"], "CUSTOMERS": ["NAME"]]),
        grammar: .ansi,
        vocabulary: .generic
    )

    @Test("A join condition's qualified column keeps the alias and spells the column")
    func joinConditionColumn() async {
        let text = "SELECT * FROM ORDERS o JOIN CUSTOMERS c ON tot"
        let session = await provider.completionSession(text: text, cursorPosition: (text as NSString).length)
        let spelled = applied(session.items, .lower, prefix: "tot")
        #expect(spelled.contains { $0.insertText == "o.total" })
    }

    @Test("All columns of a quoted reference keep its quotes")
    func quotedReferenceStar() async {
        let text = "SELECT  FROM \"Orders\""
        let session = await provider.completionSession(text: text, cursorPosition: 7)
        let spelled = applied(session.items, .asStored)
        #expect(spelled.contains { $0.insertText == "\"Orders\".*" })
    }
}
