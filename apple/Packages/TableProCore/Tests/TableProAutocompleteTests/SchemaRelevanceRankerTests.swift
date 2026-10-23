import Foundation
@testable import TableProAutocomplete
import Testing

struct SchemaRelevanceRankerTests {
    private let documents = [
        SchemaRelevanceDocument(name: "audit_log", details: ["id", "created_at", "message"]),
        SchemaRelevanceDocument(name: "customers", details: ["id", "email", "full_name"]),
        SchemaRelevanceDocument(name: "order_items", details: ["order_id", "product_id", "quantity"]),
        SchemaRelevanceDocument(name: "orders", details: ["id", "customer_id", "total_amount", "created_at"]),
        SchemaRelevanceDocument(name: "products", details: ["id", "title", "price"]),
        SchemaRelevanceDocument(name: "ProductCategory", details: ["id", "label"])
    ]

    private func names(_ query: String) -> [String] {
        SchemaRelevanceRanker.rank(documents, for: query).map { documents[$0].name }
    }

    @Test("Splits snake case, camel case and digits into folded, stemmed words")
    func splitsIdentifiers() {
        #expect(SchemaRelevanceRanker.words(in: "order_items") == ["order", "item"])
        #expect(SchemaRelevanceRanker.words(in: "ProductCategories") == ["product", "category"])
        #expect(SchemaRelevanceRanker.words(in: "userId2fa") == ["user", "id", "2", "fa"])
        #expect(SchemaRelevanceRanker.words(in: "Đơn hàng") == ["don", "hang"])
    }

    @Test("A table named in the question ranks first")
    func namedTableRanksFirst() {
        #expect(names("total amount of orders per customer").first == "orders")
    }

    @Test("A word that only a column holds still finds its table")
    func columnWordFindsTable() {
        #expect(names("which rows have an email").first == "customers")
    }

    @Test("A misspelled table name matches by trigrams")
    func typoMatches() {
        #expect(names("list all custmers").first == "customers")
    }

    @Test("A camel case table matches its plural words")
    func camelCaseMatches() {
        #expect(names("product categories").contains("ProductCategory"))
    }

    @Test("A question that matches nothing ranks nothing")
    func noMatchIsEmpty() {
        #expect(names("hello there").isEmpty)
        #expect(SchemaRelevanceRanker.rank(documents, for: "").isEmpty)
        #expect(SchemaRelevanceRanker.rank([], for: "orders").isEmpty)
    }

    @Test("A table name inside a longer word gets no name boost")
    func nameInsideLongerWordIsNotBoosted() {
        let documents = [
            SchemaRelevanceDocument(name: "data"),
            SchemaRelevanceDocument(name: "events", details: ["metadata"])
        ]
        #expect(SchemaRelevanceRanker.rank(documents, for: "show the metadata").first == 1)
    }

    @Test("Equal scores keep the listed order")
    func tiesKeepListedOrder() {
        let twins = [
            SchemaRelevanceDocument(name: "b_events"),
            SchemaRelevanceDocument(name: "a_events")
        ]
        #expect(SchemaRelevanceRanker.rank(twins, for: "events") == [0, 1])
    }
}
