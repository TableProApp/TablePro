//
//  DocumentStoreCaseSensitivityTests.swift
//  TableProTests
//
//  Case sensitivity in the drivers that match without SQL (#2048)
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MongoDB Case Sensitivity")
struct MongoDBCaseSensitivityTests {
    private let builder = MongoDBQueryBuilder()

    private func document(_ op: String, _ value: String, isCaseSensitive: Bool) -> String {
        builder.buildFilterDocument(from: [
            PluginQueryFilter(column: "name", op: op, value: value, isCaseSensitive: isCaseSensitive)
        ])
    }

    @Test("Contains ignoring case asks for the ignore-case option")
    func testContainsIgnoringCase() {
        #expect(document("CONTAINS", "ali", isCaseSensitive: false).contains("\"$options\": \"i\""))
    }

    @Test("Contains matching case asks for no option")
    func testContainsMatchingCase() {
        #expect(!document("CONTAINS", "ali", isCaseSensitive: true).contains("$options"))
    }

    @Test("Starts with and ends with follow the same setting")
    func testAnchoredOperators() {
        #expect(document("STARTS WITH", "a", isCaseSensitive: false).contains("\"$options\": \"i\""))
        #expect(!document("ENDS WITH", "a", isCaseSensitive: true).contains("$options"))
    }

    @Test("Equals matching case stays an exact value match")
    func testEqualsMatchingCase() {
        #expect(document("=", "Alice", isCaseSensitive: true) == "{\"name\": \"Alice\"}")
    }

    @Test("Equals ignoring case becomes an anchored ignore-case match")
    func testEqualsIgnoringCase() {
        let doc = document("=", "Alice", isCaseSensitive: false)
        #expect(doc.contains("^Alice$"))
        #expect(doc.contains("\"$options\": \"i\""))
    }

    @Test("Equals ignoring case escapes regex metacharacters in the value")
    func testEqualsIgnoringCaseEscapes() {
        #expect(document("=", "a.b", isCaseSensitive: false).contains("^a\\\\.b$"))
    }

    @Test("IN matching case keeps the list operator")
    func testInListMatchingCase() {
        #expect(document("IN", "a,b", isCaseSensitive: true).contains("$in"))
    }

    @Test("IN ignoring case becomes a set of anchored matches")
    func testInListIgnoringCase() {
        let doc = document("IN", "a,b", isCaseSensitive: false)
        #expect(doc.contains("$or"))
        #expect(doc.contains("^a$"))
        #expect(doc.contains("^b$"))
    }

    @Test("NOT IN ignoring case negates the whole set")
    func testNotInListIgnoringCase() {
        #expect(document("NOT IN", "a,b", isCaseSensitive: false).contains("$nor"))
    }
}

@Suite("Elasticsearch Case Sensitivity")
struct ElasticsearchCaseSensitivityTests {
    private let keywordField = ["status": ElasticsearchFieldInfo(type: "keyword", hasKeywordSubfield: false)]

    private func clause(_ op: String, _ value: String, isCaseSensitive: Bool) -> [String: Any] {
        ElasticsearchQueryBuilder.clause(
            for: ElasticsearchFilterSpec(
                column: "status", op: op, value: value, caseSensitive: isCaseSensitive
            ),
            fields: keywordField
        )
    }

    @Test("Contains ignoring case sets the wildcard option")
    func testContainsIgnoringCase() {
        let wildcard = clause("CONTAINS", "x", isCaseSensitive: false)["wildcard"] as? [String: Any]
        let options = wildcard?["status"] as? [String: Any]
        #expect(options?["case_insensitive"] as? Bool == true)
    }

    @Test("Contains matching case leaves the option off")
    func testContainsMatchingCase() {
        let wildcard = clause("CONTAINS", "x", isCaseSensitive: true)["wildcard"] as? [String: Any]
        let options = wildcard?["status"] as? [String: Any]
        #expect(options?["case_insensitive"] == nil)
    }

    @Test("Equals ignoring case uses a term with the option")
    func testEqualsIgnoringCase() {
        let term = clause("=", "active", isCaseSensitive: false)["term"] as? [String: Any]
        let options = term?["status"] as? [String: Any]
        #expect(options?["case_insensitive"] as? Bool == true)
        #expect(options?["value"] as? String == "active")
    }

    @Test("IN matching case keeps the terms query")
    func testInListMatchingCase() {
        #expect(clause("IN", "a,b", isCaseSensitive: true)["terms"] != nil)
    }

    @Test("IN ignoring case becomes a should of terms, since terms has no option")
    func testInListIgnoringCase() {
        let bool = clause("IN", "a,b", isCaseSensitive: false)["bool"] as? [String: Any]
        let should = bool?["should"] as? [[String: Any]]
        #expect(should?.count == 2)
        #expect(bool?["minimum_should_match"] as? Int == 1)
    }

    @Test("Regex ignoring case sets the option")
    func testRegexIgnoringCase() {
        let regexp = clause("REGEX", "a.*", isCaseSensitive: false)["regexp"] as? [String: Any]
        let options = regexp?["status"] as? [String: Any]
        #expect(options?["case_insensitive"] as? Bool == true)
    }

    @Test("A server too old for the option never receives it, whatever the row asks for")
    func testVersionGateWinsOverTheRow() {
        let gated = ElasticsearchQueryBuilder.clause(
            for: ElasticsearchFilterSpec(column: "status", op: "CONTAINS", value: "x", caseSensitive: false),
            fields: keywordField,
            supportsCaseInsensitive: false
        )
        let options = (gated["wildcard"] as? [String: Any])?["status"] as? [String: Any]
        #expect(options?["case_insensitive"] == nil)
    }

    @Test("A spec with no case setting keeps the behaviour each operator had before")
    func testOperatorDefaultsMatchPriorBehaviour() {
        #expect(ElasticsearchFilterSpec(column: "a", op: "CONTAINS", value: "x").ignoresCase)
        #expect(ElasticsearchFilterSpec(column: "a", op: "STARTS WITH", value: "x").ignoresCase)
        #expect(ElasticsearchFilterSpec(column: "a", op: "REGEX", value: "x").ignoresCase)
        #expect(ElasticsearchFilterSpec(column: "a", op: "=", value: "x").ignoresCase == false)
        #expect(ElasticsearchFilterSpec(column: "a", op: "IN", value: "x").ignoresCase == false)
    }
}

@Suite("etcd Case Sensitivity")
struct EtcdCaseSensitivityTests {
    private let builder = EtcdQueryBuilder()

    private func parsed(_ isCaseSensitive: Bool) -> EtcdParsedQuery? {
        let query = builder.buildFilteredQuery(
            prefix: "/app",
            filters: [
                PluginQueryFilter(column: "Key", op: "CONTAINS", value: "cfg", isCaseSensitive: isCaseSensitive)
            ],
            logicMode: "AND",
            sortColumns: [],
            limit: 100,
            offset: 0
        )
        return query.flatMap { EtcdQueryBuilder.parseRangeQuery($0) }
    }

    @Test("The encoded query carries the row's case setting")
    func testCaseFlagRoundTrips() {
        #expect(parsed(true)?.isCaseSensitive == true)
        #expect(parsed(false)?.isCaseSensitive == false)
    }

    @Test("The rest of the query survives the extra field")
    func testOtherFieldsSurvive() {
        let range = parsed(false)
        #expect(range?.prefix == "/app")
        #expect(range?.filterType == .contains)
        #expect(range?.filterValue == "cfg")
        #expect(range?.limit == 100)
    }
}

@Suite("BigQuery Case Sensitivity")
struct BigQueryCaseSensitivityTests {
    private func sql(_ op: String, _ value: String, isCaseSensitive: Bool) -> String {
        let query = BigQueryQueryBuilder.encodeFilteredQuery(
            table: "users", dataset: "main",
            filters: [
                PluginQueryFilter(column: "name", op: op, value: value, isCaseSensitive: isCaseSensitive)
            ],
            logicMode: "AND", sortColumns: [], limit: 10, offset: 0
        )
        guard let params = BigQueryQueryBuilder.decode(query) else { return "" }
        return BigQueryQueryBuilder.buildSQL(from: params, projectId: "p", columns: ["name"])
    }

    @Test("Contains ignoring case folds both sides")
    func testContainsIgnoringCase() {
        let generated = sql("CONTAINS", "ali", isCaseSensitive: false)
        #expect(generated.contains("LOWER(CAST(`name` AS STRING)) LIKE LOWER('%ali%')"))
    }

    @Test("Contains matching case stays untouched")
    func testContainsMatchingCase() {
        #expect(sql("CONTAINS", "ali", isCaseSensitive: true).contains("CAST(`name` AS STRING) LIKE '%ali%'"))
    }

    @Test("Equals ignoring case folds both sides")
    func testEqualsIgnoringCase() {
        #expect(sql("=", "Alice", isCaseSensitive: false).contains("LOWER(`name`) = LOWER('Alice')"))
    }

    @Test("BigQuery never emits an ESCAPE clause, which it does not support")
    func testNoEscapeClause() {
        #expect(!sql("CONTAINS", "ali", isCaseSensitive: false).contains("ESCAPE"))
        #expect(!sql("CONTAINS", "ali", isCaseSensitive: true).contains("ESCAPE"))
    }
}

@Suite("DynamoDB Case Sensitivity")
struct DynamoDBCaseSensitivityTests {
    @Test("A scan tag saved before this option existed keeps each operator's old behaviour")
    func testLegacySpecDefaults() {
        #expect(DynamoDBFilterSpec(column: "a", op: "CONTAINS", value: "x").ignoresCase)
        #expect(DynamoDBFilterSpec(column: "a", op: "STARTS WITH", value: "x").ignoresCase)
        #expect(DynamoDBFilterSpec(column: "a", op: "ENDS WITH", value: "x").ignoresCase)
        #expect(DynamoDBFilterSpec(column: "a", op: "=", value: "x").ignoresCase == false)
        #expect(DynamoDBFilterSpec(column: "a", op: "!=", value: "x").ignoresCase == false)
    }

    @Test("An explicit setting wins over the operator default")
    func testExplicitSettingWins() {
        #expect(DynamoDBFilterSpec(column: "a", op: "CONTAINS", value: "x", caseSensitive: true).ignoresCase == false)
        #expect(DynamoDBFilterSpec(column: "a", op: "=", value: "x", caseSensitive: false).ignoresCase)
    }

    @Test("The setting survives the encode and decode round trip")
    func testRoundTrip() throws {
        let query = DynamoDBQueryBuilder().buildFilteredQuery(
            table: "Users",
            filters: [PluginQueryFilter(column: "name", op: "CONTAINS", value: "al", isCaseSensitive: true)],
            logicMode: "AND", sortColumns: [], columns: [], limit: 10, offset: 0,
            keySchema: []
        )
        let parsed = try #require(query.flatMap { DynamoDBQueryBuilder.parseScanQuery($0) })
        #expect(parsed.filters.first?.ignoresCase == false)
    }
}
