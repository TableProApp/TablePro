import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

private struct StubCatalog: SQLCompletionCatalog {
    let tables: [String]
    let columns: [String: [String]]

    func resolveAlias(_ aliasOrName: String, in references: [TableReference]) -> String? {
        let name = aliasOrName.lowercased()
        if let match = references.first(where: { $0.alias?.lowercased() == name }) {
            return match.tableName
        }
        if let match = references.first(where: { $0.tableName.lowercased() == name }) {
            return match.tableName
        }
        return tables.first { $0.lowercased() == name }
    }

    func columnCompletionItems(for tableName: String, schema: String?) -> [SQLCompletionItem] {
        (columns[tableName.lowercased()] ?? []).map { SQLCompletionItem.column($0, dataType: nil, tableName: tableName) }
    }

    func tableCompletionItems() -> [SQLCompletionItem] {
        tables.map { SQLCompletionItem.table($0) }
    }

    func tableCompletionItems(inSchema schema: String) -> [SQLCompletionItem] { [] }
    func schemaCompletionItems() -> [SQLCompletionItem] { [] }
    func namespaceCompletionItems() -> [SQLCompletionItem] { [] }
    func isKnownSchema(_ name: String) -> Bool { false }
    func isKnownDatabase(_ name: String) -> Bool { false }
    func allowedValues(forColumn column: String, in references: [TableReference]) -> [String] { [] }

    func allColumnsInScope(for references: [TableReference]) -> [SQLCompletionItem] {
        references.flatMap { columnCompletionItems(for: $0.tableName, schema: $0.schema) }
    }

    func allColumnsFromCachedTables() -> [SQLCompletionItem] { [] }
}

struct SQLCompletionProviderCatalogTests {
    private let provider = SQLCompletionProvider(
        catalog: StubCatalog(tables: ["customers", "orders"], columns: ["orders": ["id", "total"]]),
        grammar: .engine("SQLite"),
        vocabulary: .generic
    )

    @Test("A table slot leads with the table the prefix names")
    func tableSlotLeadsWithTheTable() async {
        let session = await provider.completionSession(text: "SELECT * FROM or", cursorPosition: 16)
        #expect(session.items.first?.label == "orders")
    }

    @Test("An alias with a dot offers its table's columns")
    func aliasDotOffersColumns() async {
        let session = await provider.completionSession(text: "SELECT o. FROM orders o", cursorPosition: 9)
        #expect(Set(session.items.map(\.label)) == ["id", "total"])
    }

    @Test("UPDATE offers tables")
    func updateOffersTables() async {
        let session = await provider.completionSession(text: "UPDATE or", cursorPosition: 9)
        #expect(session.items.contains { $0.label == "orders" && $0.kind == .table })
    }

    @Test("A cursor in a string offers nothing")
    func stringOffersNothing() async {
        let text = "SELECT * FROM orders WHERE note = 'or"
        let session = await provider.completionSession(text: text, cursorPosition: (text as NSString).length)
        #expect(session.items.isEmpty)
        #expect(session.context.isInsideString)
    }

    @Test("A quoted name with a space ranks on the whole name")
    func quotedNameRanksOnTheWholeName() async {
        let provider = SQLCompletionProvider(
            catalog: StubCatalog(tables: ["Details", "Order Details", "orders"], columns: [:]),
            grammar: .engine("SQL Server"),
            vocabulary: .generic
        )
        let session = await provider.completionSession(text: "SELECT * FROM [Order Det]", cursorPosition: 24)
        #expect(session.items.first?.label == "Order Details")
        #expect(!session.items.contains { $0.label == "Details" })
    }

    // `[ord|]` offered ORDER BY and LEFT OUTER JOIN, which an accept wrote between the brackets.
    @Test("Inside a quoted name only names are offered")
    func quotedNameOffersOnlyNames() async {
        let provider = SQLCompletionProvider(
            catalog: StubCatalog(tables: ["orders"], columns: [:]),
            grammar: .engine("SQL Server"),
            vocabulary: .generic
        )
        let quoted = await provider.completionSession(text: "SELECT * FROM [ord]", cursorPosition: 18)
        #expect(quoted.items.contains { $0.label == "orders" })
        #expect(!quoted.items.contains { $0.kind == .keyword })

        let bare = await provider.completionSession(text: "SELECT * FROM ord", cursorPosition: 17)
        #expect(bare.items.contains { $0.kind == .keyword })
    }

    @Test("A vocabulary's statement completions replace the generic statement keywords")
    func vocabularyStatementCompletions() {
        let custom = SQLCompletionProvider(
            catalog: nil,
            grammar: .ansi,
            vocabulary: SQLCompletionVocabulary(statementCompletions: [.init(label: "FIND", insertText: "FIND ")])
        )
        #expect(custom.statementStartCompletionItems().map(\.label) == ["FIND"])
        #expect(provider.statementStartCompletionItems().contains { $0.label == "SELECT" })
    }
}
