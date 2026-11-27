import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

struct SQLCompletionNameIndexTests {
    // Prefix, contains and subsequence matches, mixed case, views, and names only the provider's matcher folds.
    private static let tables: [String] = {
        var names: [String] = []
        for index in 0..<1_500 {
            names.append("orders_\(index)")
            names.append("Customer_Orders_\(index)")
            names.append("o_r_d_\(index)")
        }
        names += ["orders", "ORD", "o", "order line", "Đơn_hàng", "café_orders", "ÖRDERS", "ord\u{0301}ers", "tab\tle"]
        return names
    }()

    private static let views: Set<String> = ["orders_7", "Customer_Orders_12", "café_orders", "o_r_d_3"]

    private func provider(indexed: Bool) -> SQLCompletionProvider {
        let catalog = StubCatalog(tables: Self.tables, columns: [:], views: Self.views, indexesTables: indexed)
        return SQLCompletionProvider(catalog: catalog, grammar: .ansi, vocabulary: .generic)
    }

    private struct Ranked: Equatable {
        let label: String
        let kind: SQLCompletionKind
        let matchedRanges: [Range<Int>]
        let fuzzyPenalty: Int

        init(_ item: SQLCompletionItem) {
            label = item.label
            kind = item.kind
            matchedRanges = item.matchedRanges
            fuzzyPenalty = item.fuzzyPenalty
        }
    }

    @Test(
        "an indexed table list ranks exactly as the same tables handed over as items",
        arguments: [
            "SELECT * FROM ", "SELECT * FROM o", "SELECT * FROM or", "SELECT * FROM ord", "SELECT * FROM ORD",
            "SELECT * FROM orders", "SELECT * FROM rd", "SELECT * FROM od", "SELECT * FROM _1", "SELECT * FROM x",
            "SELECT * FROM café", "SELECT * FROM đ", "SELECT * FROM ö", "SELECT * FROM o_r_d_149",
            "SELECT * FROM \"or", "SELECT * FROM orders a JOIN ", "SELECT * FROM orders a JOIN cu",
            "INSERT INTO o", "DROP TABLE ord", "CREATE VIEW v AS ", "o", "or", "SEL", "s", ""
        ]
    )
    func indexRanksLikeItems(query: String) async {
        let caret = (query as NSString).length
        let plain = await provider(indexed: false).completionSession(text: query, cursorPosition: caret)
        let indexed = await provider(indexed: true).completionSession(text: query, cursorPosition: caret)

        #expect(indexed.items.map(Ranked.init) == plain.items.map(Ranked.init))
        #expect(indexed.candidates.map(Ranked.init) == plain.candidates.map(Ranked.init))
        #expect(indexed.candidatesTruncated == plain.candidatesTruncated)
    }

    @Test("a prefix range holds exactly the names that start with it, in key order")
    func prefixRangeHoldsThePrefixedNames() {
        let index = SQLCompletionNameIndex(tables: ["b", "ab", "abc", "Abd", "a", "ac", "x"].map { ($0, false) })
        let keys = { (prefix: String) in
            index.prefixRange(SQLCompletionNameIndex.simpleKey(prefix) ?? []).map { index.names[Int(index.sortedRows[$0])] }
        }

        #expect(keys("ab") == ["ab", "abc", "Abd"])
        #expect(keys("a") == ["a", "ab", "abc", "Abd", "ac"])
        #expect(keys("abcd").isEmpty)
        #expect(keys("") == ["a", "ab", "abc", "Abd", "ac", "b", "x"])
    }

    @Test("a suppressed request at a statement start answers nothing")
    func suppressedRequestAnswersNothing() async {
        let catalog = StubCatalog(tables: Self.tables, columns: [:], indexesTables: true)
        let provider = SQLCompletionProvider(catalog: catalog, grammar: .ansi, vocabulary: .generic)

        let suppressed = await provider.completionSession(text: "  ", cursorPosition: 2, suppressesEmptyPrefix: true)
        let asked = await provider.completionSession(text: "  ", cursorPosition: 2)

        #expect(suppressed.items.isEmpty)
        #expect(asked.items.contains { $0.label == "orders" })
    }
}
