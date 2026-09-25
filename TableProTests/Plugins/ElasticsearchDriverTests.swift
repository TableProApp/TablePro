//
//  ElasticsearchDriverTests.swift
//  TableProTests
//
//  Tests for Elasticsearch plugin pure logic (compiled via symlinks from ElasticsearchDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

struct ElasticsearchConsoleParserTests {
    @Test("Parses method, path, and JSON body")
    func parsesFullRequest() {
        let input = "POST /my-index/_search\n{\n  \"query\": { \"match_all\": {} }\n}"
        let request = ElasticsearchConsoleParser.parse(input)
        #expect(request?.method == "POST")
        #expect(request?.path == "/my-index/_search")
        #expect(request?.body?.contains("match_all") == true)
    }

    @Test("Normalizes a path without a leading slash")
    func normalizesPath() {
        let request = ElasticsearchConsoleParser.parse("GET _cat/indices?format=json")
        #expect(request?.method == "GET")
        #expect(request?.path == "/_cat/indices?format=json")
        #expect(request?.body == nil)
    }

    @Test("Lowercase method is normalized")
    func uppercasesMethod() {
        #expect(ElasticsearchConsoleParser.parse("get /")?.method == "GET")
    }

    @Test("Rejects unsupported method")
    func rejectsUnknownMethod() {
        #expect(ElasticsearchConsoleParser.parse("FETCH /index") == nil)
        #expect(ElasticsearchConsoleParser.parse("") == nil)
    }
}

struct ElasticsearchQueryBuilderEncodingTests {
    private let builder = ElasticsearchQueryBuilder()

    @Test("Browse query round-trips")
    func browseRoundTrip() {
        let query = builder.buildBrowseQuery(index: "logs", sorts: [], limit: 50, offset: 10)
        #expect(query.hasPrefix(ElasticsearchQueryBuilder.searchTag))
        let parsed = ElasticsearchQueryBuilder.parseSearch(query)
        #expect(parsed?.index == "logs")
        #expect(parsed?.from == 10)
        #expect(parsed?.size == 50)
        #expect(parsed?.filters.isEmpty == true)
    }

    @Test("Filtered query preserves filters and sorts")
    func filteredRoundTrip() {
        let query = builder.buildFilteredQuery(
            index: "users",
            filters: [PluginQueryFilter(column: "age", op: ">", value: "21")],
            logicMode: "AND",
            sorts: [ElasticsearchSortSpec(column: "name", ascending: true)],
            limit: 100,
            offset: 0
        )
        let parsed = ElasticsearchQueryBuilder.parseSearch(query)
        #expect(parsed?.filters.first?.column == "age")
        #expect(parsed?.filters.first?.op == ">")
        #expect(parsed?.sorts.first?.column == "name")
        #expect(parsed?.sorts.first?.ascending == true)
    }
}

struct ElasticsearchQueryDSLTests {
    private let textField = ["title": ElasticsearchFieldInfo(type: "text", hasKeywordSubfield: true)]
    private let keywordField = ["status": ElasticsearchFieldInfo(type: "keyword", hasKeywordSubfield: false)]
    private let numericField = ["age": ElasticsearchFieldInfo(type: "long", hasKeywordSubfield: false)]
    private let nestedLeafFields = [
        "identifiers.type": ElasticsearchFieldInfo(
            type: "keyword", hasKeywordSubfield: false, nestedPaths: ["identifiers"]
        ),
        "identifiers.value": ElasticsearchFieldInfo(
            type: "keyword", hasKeywordSubfield: false, nestedPaths: ["identifiers"]
        ),
    ]

    @Test("Empty filters produce match_all")
    func matchAll() {
        let clause = ElasticsearchQueryBuilder.queryClause(filters: [], logicMode: "AND", fields: [:])
        #expect(clause["match_all"] != nil)
    }

    @Test("Equality on keyword uses term")
    func keywordTerm() {
        let filter = ElasticsearchFilterSpec(column: "status", op: "=", value: "active")
        let clause = ElasticsearchQueryBuilder.clause(for: filter, fields: keywordField)
        let term = clause["term"] as? [String: Any]
        #expect(term?["status"] as? String == "active")
    }

    @Test("Numeric range uses typed value")
    func numericRange() {
        let filter = ElasticsearchFilterSpec(column: "age", op: ">", value: "21")
        let clause = ElasticsearchQueryBuilder.clause(for: filter, fields: numericField)
        let range = clause["range"] as? [String: Any]
        let bounds = range?["age"] as? [String: Any]
        #expect(bounds?["gt"] as? Int == 21)
    }

    @Test("Sorting a text field targets its keyword subfield")
    func sortUsesKeyword() {
        let field = ElasticsearchQueryBuilder.sortableField("title", fields: textField)
        #expect(field == "title.keyword")
    }

    @Test("OR logic builds should with minimum_should_match")
    func orLogic() {
        let filters = [
            ElasticsearchFilterSpec(column: "status", op: "=", value: "a"),
            ElasticsearchFilterSpec(column: "status", op: "=", value: "b"),
        ]
        let clause = ElasticsearchQueryBuilder.queryClause(filters: filters, logicMode: "OR", fields: keywordField)
        let bool = clause["bool"] as? [String: Any]
        #expect(bool?["should"] != nil)
        #expect(bool?["minimum_should_match"] as? Int == 1)
    }

    @Test("IS NULL negates presence, so an absent field matches")
    func isNull() {
        let filter = ElasticsearchFilterSpec(column: "status", op: "IS NULL", value: "")
        let clause = ElasticsearchQueryBuilder.clause(for: filter, fields: keywordField)
        let outer = (clause["bool"] as? [String: Any])?["must_not"] as? [[String: Any]]
        let present = (outer?.first?["bool"] as? [String: Any])
        #expect((present?["must"] as? [[String: Any]])?.first?["exists"] != nil)
        #expect((present?["must_not"] as? [[String: Any]])?.first?["term"] != nil)
    }

    @Test("IS NOT NULL asks for presence directly")
    func isNotNull() {
        let filter = ElasticsearchFilterSpec(column: "status", op: "IS NOT NULL", value: "")
        let clause = ElasticsearchQueryBuilder.clause(for: filter, fields: keywordField)
        let bool = clause["bool"] as? [String: Any]
        #expect((bool?["must"] as? [[String: Any]])?.first?["exists"] != nil)
        #expect((bool?["must_not"] as? [[String: Any]])?.first?["term"] != nil)
    }

    @Test("Deep pagination body includes _shard_doc tiebreaker")
    func tiebreaker() {
        let parsed = ElasticsearchParsedSearch(index: "i", from: 0, size: 10, sorts: [], filters: [], logicMode: "AND")
        let body = ElasticsearchQueryBuilder.searchBody(for: parsed, fields: [:], size: 10, tiebreaker: true)
        let sort = body["sort"] as? [[String: Any]]
        #expect(sort?.contains { $0["_shard_doc"] != nil } == true)
    }

    @Test("Raw filter sentinel builds a query_string")
    func rawFilter() {
        let filter = ElasticsearchFilterSpec(column: "__RAW__", op: "=", value: "Widget")
        let clause = ElasticsearchQueryBuilder.clause(for: filter, fields: [:])
        let queryString = clause["query_string"] as? [String: Any]
        #expect(queryString?["query"] as? String == "Widget")
    }

    @Test("Empty raw filter is ignored (match_all)")
    func emptyRawFilter() {
        let filters = [ElasticsearchFilterSpec(column: "__RAW__", op: "=", value: "")]
        let clause = ElasticsearchQueryBuilder.queryClause(filters: filters, logicMode: "AND", fields: [:])
        #expect(clause["match_all"] != nil)
    }

    @Test("_id is not sortable (returns nil)")
    func idNotSortable() {
        #expect(ElasticsearchQueryBuilder.sortableField("_id", fields: [:]) == nil)
        #expect(ElasticsearchQueryBuilder.sortableField("_score", fields: [:]) == "_score")
    }

    @Test("BETWEEN builds a gte/lte range")
    func betweenRange() {
        let clause = ElasticsearchQueryBuilder.clause(
            for: ElasticsearchFilterSpec(column: "age", op: "BETWEEN", value: "10,20"),
            fields: numericField
        )
        let bounds = (clause["range"] as? [String: Any])?["age"] as? [String: Any]
        #expect(bounds?["gte"] as? Int == 10)
        #expect(bounds?["lte"] as? Int == 20)
    }

    @Test("NOT CONTAINS and NOT IN wrap in must_not")
    func negatedClauses() {
        let notContains = ElasticsearchQueryBuilder.clause(
            for: ElasticsearchFilterSpec(column: "status", op: "NOT CONTAINS", value: "x"), fields: keywordField
        )
        #expect((notContains["bool"] as? [String: Any])?["must_not"] != nil)
        let notIn = ElasticsearchQueryBuilder.clause(
            for: ElasticsearchFilterSpec(column: "status", op: "NOT IN", value: "a,b"), fields: keywordField
        )
        #expect((notIn["bool"] as? [String: Any])?["must_not"] != nil)
    }

    @Test("REGEX builds a regexp query")
    func regexClause() {
        let clause = ElasticsearchQueryBuilder.clause(
            for: ElasticsearchFilterSpec(column: "status", op: "REGEX", value: "a.*"), fields: keywordField
        )
        let regexp = clause["regexp"] as? [String: Any]
        #expect((regexp?["status"] as? [String: Any])?["value"] as? String == "a.*")
    }

    @Test("A nested leaf filter wraps in a nested query")
    func nestedLeafFilterWraps() {
        let fields = [
            "identifiers.type": ElasticsearchFieldInfo(
                type: "keyword", hasKeywordSubfield: false, nestedPaths: ["identifiers"]
            ),
        ]
        let clause = ElasticsearchQueryBuilder.queryClause(
            filters: [ElasticsearchFilterSpec(column: "identifiers.type", op: "=", value: "CPF")],
            logicMode: "AND",
            fields: fields
        )
        let nested = clause["nested"] as? [String: Any]
        #expect(nested?["path"] as? String == "identifiers")
        let term = (nested?["query"] as? [String: Any])?["term"] as? [String: Any]
        #expect(term?["identifiers.type"] as? String == "CPF")
    }

    @Test("Same-element nested filters share one nested query")
    func nestedSameElementGroups() {
        let fields = [
            "identifiers.type": ElasticsearchFieldInfo(
                type: "keyword", hasKeywordSubfield: false, nestedPaths: ["identifiers"]
            ),
            "identifiers.value": ElasticsearchFieldInfo(
                type: "keyword", hasKeywordSubfield: false, nestedPaths: ["identifiers"]
            ),
        ]
        let clause = ElasticsearchQueryBuilder.queryClause(
            filters: [
                ElasticsearchFilterSpec(
                    column: "identifiers.type", op: "=", value: "CPF", elementScope: "identifiers"
                ),
                ElasticsearchFilterSpec(
                    column: "identifiers.value", op: "=", value: "318.578.388-31", elementScope: "identifiers"
                ),
            ],
            logicMode: "AND",
            fields: fields
        )
        let nested = clause["nested"] as? [String: Any]
        #expect(nested?["path"] as? String == "identifiers")
        let bool = (nested?["query"] as? [String: Any])?["bool"] as? [String: Any]
        let must = bool?["must"] as? [[String: Any]]
        #expect(must?.count == 2)
    }

    @Test("Independent nested filters stay separate nested queries")
    func nestedAnyElementStaysSeparate() {
        let fields = [
            "identifiers.type": ElasticsearchFieldInfo(
                type: "keyword", hasKeywordSubfield: false, nestedPaths: ["identifiers"]
            ),
            "identifiers.issuer": ElasticsearchFieldInfo(
                type: "keyword", hasKeywordSubfield: false, nestedPaths: ["identifiers"]
            ),
        ]
        let clause = ElasticsearchQueryBuilder.queryClause(
            filters: [
                ElasticsearchFilterSpec(column: "identifiers.type", op: "=", value: "CPF"),
                ElasticsearchFilterSpec(column: "identifiers.issuer", op: "=", value: "EPACS"),
            ],
            logicMode: "AND",
            fields: fields
        )
        let must = (clause["bool"] as? [String: Any])?["must"] as? [[String: Any]]
        #expect(must?.count == 2)
        #expect(must?.allSatisfy { $0["nested"] != nil } == true)
    }

    @Test("A nested negation negates the nested query, not its body")
    func nestedNegationWrapsOutside() {
        let clause = ElasticsearchQueryBuilder.queryClause(
            filters: [ElasticsearchFilterSpec(column: "identifiers.type", op: "!=", value: "CPF")],
            logicMode: "AND",
            fields: nestedLeafFields
        )
        let mustNot = (clause["bool"] as? [String: Any])?["must_not"] as? [[String: Any]]
        let nested = mustNot?.first?["nested"] as? [String: Any]
        #expect(nested?["path"] as? String == "identifiers")
        #expect((nested?["query"] as? [String: Any])?["term"] != nil)
    }

    @Test("IS NULL on a nested leaf negates the whole nested query")
    func nestedIsNullWrapsOutside() {
        let clause = ElasticsearchQueryBuilder.queryClause(
            filters: [ElasticsearchFilterSpec(column: "identifiers.type", op: "IS NULL", value: "")],
            logicMode: "AND",
            fields: nestedLeafFields
        )
        let mustNot = (clause["bool"] as? [String: Any])?["must_not"] as? [[String: Any]]
        #expect(mustNot?.first?["nested"] != nil)
    }

    @Test("A nested query ignores an unmapped path")
    func nestedIgnoresUnmapped() {
        let clause = ElasticsearchQueryBuilder.queryClause(
            filters: [ElasticsearchFilterSpec(column: "identifiers.type", op: "=", value: "CPF")],
            logicMode: "AND",
            fields: nestedLeafFields
        )
        #expect((clause["nested"] as? [String: Any])?["ignore_unmapped"] as? Bool == true)
    }

    @Test("A filter on a nested parent column is dropped, not sent as a term")
    func nestedParentFilterDropped() {
        let fields = [
            "identifiers": ElasticsearchFieldInfo(type: "nested", hasKeywordSubfield: false),
            "personId": ElasticsearchFieldInfo(type: "keyword", hasKeywordSubfield: false),
        ]
        let dropped = ElasticsearchQueryBuilder.queryClause(
            filters: [ElasticsearchFilterSpec(column: "identifiers", op: "=", value: "anything")],
            logicMode: "AND",
            fields: fields
        )
        #expect(dropped["match_all"] != nil)

        let kept = ElasticsearchQueryBuilder.queryClause(
            filters: [
                ElasticsearchFilterSpec(column: "identifiers", op: "=", value: "anything"),
                ElasticsearchFilterSpec(column: "personId", op: "=", value: "p1"),
            ],
            logicMode: "AND",
            fields: fields
        )
        #expect(kept["term"] != nil)
    }

    @Test("A leaf under two nested ancestors enters both scopes, outermost first")
    func doublyNestedWrapsBothScopes() {
        let fields = [
            "orders.items.sku": ElasticsearchFieldInfo(
                type: "keyword", hasKeywordSubfield: false, nestedPaths: ["orders", "orders.items"]
            ),
        ]
        let clause = ElasticsearchQueryBuilder.queryClause(
            filters: [ElasticsearchFilterSpec(column: "orders.items.sku", op: "=", value: "A1")],
            logicMode: "AND",
            fields: fields
        )
        let outer = clause["nested"] as? [String: Any]
        #expect(outer?["path"] as? String == "orders")
        let inner = (outer?["query"] as? [String: Any])?["nested"] as? [String: Any]
        #expect(inner?["path"] as? String == "orders.items")
        #expect((inner?["query"] as? [String: Any])?["term"] != nil)
    }

    @Test("A same-element group keeps a negation inside the one nested query")
    func sameElementGroupNegatesInside() {
        let clause = ElasticsearchQueryBuilder.queryClause(
            filters: [
                ElasticsearchFilterSpec(
                    column: "identifiers.type", op: "=", value: "CPF", elementScope: "identifiers"
                ),
                ElasticsearchFilterSpec(
                    column: "identifiers.value", op: "!=", value: "0", elementScope: "identifiers"
                ),
            ],
            logicMode: "AND",
            fields: nestedLeafFields
        )
        let nested = clause["nested"] as? [String: Any]
        #expect(nested?["path"] as? String == "identifiers")
        let must = ((nested?["query"] as? [String: Any])?["bool"] as? [String: Any])?["must"] as? [[String: Any]]
        #expect(must?.count == 2)
        #expect(must?.contains { ($0["bool"] as? [String: Any])?["must_not"] != nil } == true)
    }

    @Test("One scoped filter reads as any element, so its negation stays outside")
    func loneScopedNegationWrapsOutside() {
        let clause = ElasticsearchQueryBuilder.queryClause(
            filters: [
                ElasticsearchFilterSpec(
                    column: "identifiers.type", op: "!=", value: "CPF", elementScope: "identifiers"
                ),
            ],
            logicMode: "AND",
            fields: nestedLeafFields
        )
        let mustNot = (clause["bool"] as? [String: Any])?["must_not"] as? [[String: Any]]
        #expect(mustNot?.first?["nested"] != nil)
    }

    @Test("One scope over two nested depths does not merge into one scope")
    func sameScopeDifferentDepthsStaySeparate() {
        let fields = [
            "orders.ref": ElasticsearchFieldInfo(
                type: "keyword", hasKeywordSubfield: false, nestedPaths: ["orders"]
            ),
            "orders.items.sku": ElasticsearchFieldInfo(
                type: "keyword", hasKeywordSubfield: false, nestedPaths: ["orders", "orders.items"]
            ),
        ]
        let clause = ElasticsearchQueryBuilder.queryClause(
            filters: [
                ElasticsearchFilterSpec(column: "orders.ref", op: "=", value: "R1", elementScope: "orders"),
                ElasticsearchFilterSpec(column: "orders.items.sku", op: "=", value: "A1", elementScope: "orders"),
            ],
            logicMode: "AND",
            fields: fields
        )
        let must = (clause["bool"] as? [String: Any])?["must"] as? [[String: Any]]
        #expect(must?.count == 2)
        let paths = must?.compactMap { ($0["nested"] as? [String: Any])?["path"] as? String }
        #expect(paths == ["orders", "orders"])
        let inner = must?.compactMap { clause -> String? in
            let nested = clause["nested"] as? [String: Any]
            let query = nested?["query"] as? [String: Any]
            return (query?["nested"] as? [String: Any])?["path"] as? String
        }
        #expect(inner == ["orders.items"])
    }

    @Test("Sorting a doubly nested leaf names both scopes")
    func doublyNestedSortNamesBothScopes() {
        let fields = [
            "orders.items.sku": ElasticsearchFieldInfo(
                type: "keyword", hasKeywordSubfield: false, nestedPaths: ["orders", "orders.items"]
            ),
        ]
        let sorts = ElasticsearchQueryBuilder.sortClause(
            [ElasticsearchSortSpec(column: "orders.items.sku", ascending: true)],
            fields: fields,
            tiebreaker: false
        )
        let options = sorts.first?["orders.items.sku"] as? [String: Any]
        let outer = options?["nested"] as? [String: Any]
        #expect(outer?["path"] as? String == "orders")
        #expect((outer?["nested"] as? [String: Any])?["path"] as? String == "orders.items")
    }

    @Test("A nested parent column is not sortable")
    func nestedParentNotSortable() {
        let fields = ["identifiers": ElasticsearchFieldInfo(type: "nested", hasKeywordSubfield: false)]
        #expect(ElasticsearchQueryBuilder.sortableField("identifiers", fields: fields) == nil)
    }

    @Test("Sorting a nested leaf names the nested path")
    func nestedLeafSort() {
        let fields = [
            "identifiers.issuer": ElasticsearchFieldInfo(
                type: "keyword", hasKeywordSubfield: false, nestedPaths: ["identifiers"]
            ),
        ]
        let parsed = ElasticsearchParsedSearch(
            index: "i", from: 0, size: 10,
            sorts: [ElasticsearchSortSpec(column: "identifiers.issuer", ascending: true)],
            filters: [], logicMode: "AND"
        )
        let body = ElasticsearchQueryBuilder.searchBody(for: parsed, fields: fields, size: 10)
        let sort = body["sort"] as? [[String: Any]]
        let options = sort?.first?["identifiers.issuer"] as? [String: Any]
        #expect(options?["order"] as? String == "asc")
        #expect((options?["nested"] as? [String: Any])?["path"] as? String == "identifiers")
    }

    @Test("Tagged search round-trips elementScope")
    func elementScopeRoundTrip() {
        let tagged = ElasticsearchQueryBuilder.encodeSearch(
            index: "persons", from: 0, size: 50,
            sorts: [],
            filters: [
                ElasticsearchFilterSpec(
                    column: "identifiers.type", op: "=", value: "CPF", elementScope: "identifiers"
                ),
            ],
            logicMode: "AND"
        )
        let parsed = ElasticsearchQueryBuilder.parseSearch(tagged)
        #expect(parsed?.filters.first?.elementScope == "identifiers")
        #expect(parsed?.filters.first?.column == "identifiers.type")
    }

    @Test("specs copies elementScope from the plugin filter")
    func specsCopyElementScope() {
        let filters = [
            PluginQueryFilter(
                column: "identifiers.type",
                op: "=",
                value: "CPF",
                isCaseSensitive: true,
                secondValue: nil,
                elementScope: "identifiers"
            ),
        ]
        #expect(ElasticsearchQueryBuilder.specs(from: filters).first?.elementScope == "identifiers")
    }

    @Test("case_insensitive is omitted when unsupported (pre-7.10)")
    func caseInsensitiveGated() {
        let on = ElasticsearchQueryBuilder.clause(
            for: ElasticsearchFilterSpec(column: "status", op: "CONTAINS", value: "x"),
            fields: keywordField, supportsCaseInsensitive: true
        )
        #expect((on["wildcard"] as? [String: Any]).map { ($0["status"] as? [String: Any])?["case_insensitive"] as? Bool } == true)
        let off = ElasticsearchQueryBuilder.clause(
            for: ElasticsearchFilterSpec(column: "status", op: "CONTAINS", value: "x"),
            fields: keywordField, supportsCaseInsensitive: false
        )
        let offOptions = (off["wildcard"] as? [String: Any])?["status"] as? [String: Any]
        #expect(offOptions?["case_insensitive"] == nil)
    }
}

struct ElasticsearchOrderByTests {
    @Test("Extracts a single appended ORDER BY from the tagged query")
    func singleOrderBy() {
        let tagged = ElasticsearchQueryBuilder.encodeSearch(
            index: "products", from: 0, size: 1_000, sorts: [], filters: [], logicMode: "AND"
        )
        let (base, sorts) = ElasticsearchQueryBuilder.extractOrderBy(tagged + " ORDER BY \"name\" ASC")
        #expect(base == tagged)
        #expect(sorts == [ElasticsearchSortSpec(column: "name", ascending: true)])
        #expect(ElasticsearchQueryBuilder.parseSearch(base)?.index == "products")
    }

    @Test("Parses multi-column ORDER BY with directions")
    func multiOrderBy() {
        let sorts = ElasticsearchQueryBuilder.parseOrderByClause("\"age\" DESC, \"country\" ASC")
        #expect(sorts == [
            ElasticsearchSortSpec(column: "age", ascending: false),
            ElasticsearchSortSpec(column: "country", ascending: true),
        ])
    }

    @Test("No ORDER BY leaves the query unchanged")
    func noOrderBy() {
        let (base, sorts) = ElasticsearchQueryBuilder.extractOrderBy("ELASTICSEARCH_SEARCH:abc")
        #expect(base == "ELASTICSEARCH_SEARCH:abc")
        #expect(sorts.isEmpty)
    }
}

struct ElasticsearchMappingFlattenerTests {
    @Test("Flattens nested objects into dotted paths and records keyword subfields")
    func flattenMapping() {
        let properties: [String: Any] = [
            "name": ["type": "text", "fields": ["keyword": ["type": "keyword"]]],
            "age": ["type": "long"],
            "address": ["properties": ["city": ["type": "keyword"]]],
        ]
        let columns = ElasticsearchMappingFlattener.flattenMapping(properties: properties)
        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
        #expect(byName["name"]?.type == "text")
        #expect(byName["name"]?.hasKeywordSubfield == true)
        #expect(byName["age"]?.type == "long")
        #expect(byName["address.city"]?.type == "keyword")
        #expect(byName["address"] == nil)
        #expect(byName["address.city"]?.nestedPath == nil)
    }

    @Test("Keeps a nested parent column and marks its leaves with the nested path")
    func nestedMappingKeepsParentAndMarksLeaves() {
        let properties: [String: Any] = [
            "personId": ["type": "keyword"],
            "identifiers": [
                "type": "nested",
                "properties": [
                    "issuer": ["type": "keyword"],
                    "system": ["type": "keyword"],
                    "type": ["type": "keyword"],
                    "value": ["type": "keyword"],
                ],
            ],
        ]
        let columns = ElasticsearchMappingFlattener.flattenMapping(properties: properties)
        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
        #expect(byName["identifiers"]?.type == "nested")
        #expect(byName["identifiers"]?.nestedPath == nil)
        #expect(byName["identifiers.issuer"]?.type == "keyword")
        #expect(byName["identifiers.issuer"]?.nestedPath == "identifiers")
        #expect(byName["identifiers.type"]?.nestedPath == "identifiers")
        #expect(byName["personId"]?.nestedPath == nil)
    }

    @Test("Columns include meta columns first")
    func metaColumnsFirst() {
        let mapping = [ElasticsearchColumn(name: "field", type: "keyword", hasKeywordSubfield: false)]
        let columns = ElasticsearchMappingFlattener.columns(forHits: [], mappingColumns: mapping)
        #expect(Array(columns.prefix(3)) == ["_id", "_index", "_score"])
        #expect(columns.contains("field"))
    }

    @Test("Flattens a source document and renders nested values as JSON")
    func flattenSource() {
        let source: [String: Any] = [
            "name": "Alice",
            "address": ["city": "NYC"],
            "tags": ["a", "b"],
        ]
        let flat = ElasticsearchMappingFlattener.flattenSource(source)
        #expect(flat["name"] == .text("Alice"))
        #expect(flat["address.city"] == .text("NYC"))
        #expect(flat["tags"]?.asText?.contains("a") == true)
    }

    @Test("Doubles keep every digit needed to round-trip, nested or not")
    func doublesRoundTrip() {
        let source: [String: Any] = [
            "score": -3.9192320754595876e-07,
            "total": 1847.27,
            "counts": ["rate": 0.1, "qty": 3.0],
        ]
        let flat = ElasticsearchMappingFlattener.flattenSource(source)
        #expect(flat["score"] == .text("-3.9192320754595876e-07"))
        #expect(flat["total"] == .text("1847.27"))
        #expect(flat["counts.rate"] == .text("0.1"))
        #expect(flat["counts.qty"] == .text("3"))
    }

    @Test("An array of doubles serializes without binary floating point noise")
    func arrayOfDoublesHasNoExcessDigits() {
        let source: [String: Any] = ["samples": [0.1, 1847.27]]
        let flat = ElasticsearchMappingFlattener.flattenSource(source)
        #expect(flat["samples"] == .text("[0.1,1847.27]"))
    }

    @Test("Rows pull meta fields from the hit envelope")
    func rowsWithMeta() {
        let hits: [[String: Any]] = [[
            "_id": "1", "_index": "logs", "_score": 1.5,
            "_source": ["msg": "hello"],
        ]]
        let columns = ["_id", "_index", "_score", "msg"]
        let rows = ElasticsearchMappingFlattener.rows(forHits: hits, columns: columns)
        #expect(rows.first?[0] == .text("1"))
        #expect(rows.first?[1] == .text("logs"))
        #expect(rows.first?[3] == .text("hello"))
    }

    @Test("Heterogeneous documents union their fields")
    func heterogeneousUnion() {
        let sources: [[String: Any]] = [["a": 1], ["b": 2]]
        let columns = ElasticsearchMappingFlattener.unionColumns(fromSources: sources)
        #expect(columns.contains("a"))
        #expect(columns.contains("b"))
    }

    @Test("Object-valued parent column renders as JSON, not null")
    func parentObjectColumnRendersJSON() {
        let hits: [[String: Any]] = [["_source": ["labels": ["env": "prod", "tier": "1"]]]]
        let rows = ElasticsearchMappingFlattener.rows(forHits: hits, columns: ["labels"])
        #expect(rows.first?[0].asText?.contains("env") == true)
    }

    @Test("A nested identifier array fills the parent and each leaf, never null")
    func nestedIdentifierArrayRenders() {
        let source: [String: Any] = [
            "personId": "03c47c6d-2cf6-4e3b-9d2c-0d762f77ae13",
            "identifiers": [[
                "issuer": "EPACS",
                "system": "urn:epacs:patient:600003399",
                "type": "PATIENT_ID",
                "value": "8930",
            ]],
        ]
        let hits: [[String: Any]] = [["_id": "03c47c6d-2cf6-4e3b-9d2c-0d762f77ae13", "_source": source]]
        let columns = [
            "identifiers", "identifiers.issuer", "identifiers.system",
            "identifiers.type", "identifiers.value", "personId",
        ]
        let row = ElasticsearchMappingFlattener.rows(forHits: hits, columns: columns).first
        #expect(row?[0].asText?.contains("8930") == true)
        #expect(row?[0].asText?.contains("identifiers.issuer") == false)
        #expect(row?[1].asText?.contains("EPACS") == true)
        #expect(row?[3].asText?.contains("PATIENT_ID") == true)
        #expect(row?[4].asText?.contains("8930") == true)
        #expect(row?[5] == .text("03c47c6d-2cf6-4e3b-9d2c-0d762f77ae13"))
    }

    @Test("Two nested identifiers keep both objects rather than the first only")
    func nestedIdentifierPairKeepsBoth() {
        let source: [String: Any] = [
            "personId": "0ff4afbe-7b2f-40f6-acf9-fbb6403c6250",
            "identifiers": [
                ["system": "urn:br:cpf", "type": "CPF", "value": "318.578.388-31"],
                [
                    "issuer": "EPACS",
                    "system": "urn:epacs:patient:600003399",
                    "type": "PATIENT_ID",
                    "value": "3533",
                ],
            ],
        ]
        let hits: [[String: Any]] = [["_source": source]]
        let row = ElasticsearchMappingFlattener.rows(
            forHits: hits,
            columns: ["identifiers", "identifiers.type", "identifiers.value", "identifiers.issuer"]
        ).first
        #expect(row?[0].asText?.contains("318.578.388-31") == true)
        #expect(row?[0].asText?.contains("3533") == true)
        #expect(row?[1].asText?.contains("CPF") == true)
        #expect(row?[1].asText?.contains("PATIENT_ID") == true)
        #expect(row?[2].asText?.contains("318.578.388-31") == true)
        #expect(row?[2].asText?.contains("3533") == true)
        #expect(row?[3].asText?.contains("EPACS") == true)
    }

    @Test("A missing nested field is an empty cell, not a crash")
    func missingNestedFieldIsNull() {
        let hits: [[String: Any]] = [["_source": ["personId": "1"]]]
        let rows = ElasticsearchMappingFlattener.rows(
            forHits: hits,
            columns: ["identifiers", "identifiers.value", "personId"]
        )
        #expect(rows.first?[0] == .null)
        #expect(rows.first?[1] == .null)
        #expect(rows.first?[2] == .text("1"))
    }

    @Test("An object array still fills dotted leaves")
    func objectArrayFillsDottedLeaves() {
        let hits: [[String: Any]] = [["_source": ["labels": [["env": "prod"], ["env": "dev"]]]]]
        let rows = ElasticsearchMappingFlattener.rows(forHits: hits, columns: ["labels.env"])
        let text = rows.first?[0].asText
        #expect(text?.contains("prod") == true)
        #expect(text?.contains("dev") == true)
    }

    @Test("A leaf an object omits keeps its place, so sibling columns line up")
    func nestedLeavesKeepPosition() {
        let source: [String: Any] = [
            "identifiers": [
                ["type": "CPF", "value": "318.578.388-31"],
                ["issuer": "EPACS", "type": "PATIENT_ID", "value": "3533"],
            ],
        ]
        let hits: [[String: Any]] = [["_source": source]]
        let row = ElasticsearchMappingFlattener.rows(
            forHits: hits,
            columns: ["identifiers.issuer", "identifiers.type"]
        ).first
        #expect(row?[0].asText == "[null,\"EPACS\"]")
        #expect(row?[1].asText == "[\"CPF\",\"PATIENT_ID\"]")
    }

    @Test("A bare object in a nested field renders as a one-element array")
    func bareNestedObjectRendersAsArray() {
        let hits: [[String: Any]] = [["_source": ["identifiers": ["type": "CPF"]]]]
        let row = ElasticsearchMappingFlattener.rows(
            forHits: hits,
            columns: ["identifiers", "identifiers.type"],
            nestedParents: ["identifiers"]
        ).first
        #expect(row?[0].asText?.hasPrefix("[") == true)
        #expect(row?[1].asText == "[\"CPF\"]")
    }

    @Test("An alias mapping keyed by real index names unions their fields")
    func aliasMappingUnionsEveryIndex() {
        let response: [String: Any] = [
            "logs-2026-08": ["mappings": ["properties": [
                "message": ["type": "text"],
                "level": ["type": "keyword"],
            ]]],
            "logs-2026-09": ["mappings": ["properties": [
                "message": ["type": "text"],
                "traceId": ["type": "keyword"],
            ]]],
        ]
        let properties = ElasticsearchMappingFlattener.properties(fromMappingResponse: response, index: "logs")
        #expect(Set(properties.keys) == ["message", "level", "traceId"])
    }

    @Test("A response that names the index exactly uses only that index")
    func exactIndexMappingWins() {
        let response: [String: Any] = [
            "logs-2026-08": ["mappings": ["properties": ["level": ["type": "keyword"]]]],
            "logs-2026-09": ["mappings": ["properties": ["traceId": ["type": "keyword"]]]],
        ]
        let properties = ElasticsearchMappingFlattener.properties(
            fromMappingResponse: response, index: "logs-2026-09"
        )
        #expect(Set(properties.keys) == ["traceId"])
    }

    @Test("A nested field inside a nested field reports both ancestors")
    func doublyNestedMappingReportsBothAncestors() {
        let properties: [String: Any] = [
            "orders": [
                "type": "nested",
                "properties": [
                    "ref": ["type": "keyword"],
                    "items": [
                        "type": "nested",
                        "properties": ["sku": ["type": "keyword"]],
                    ],
                ],
            ],
        ]
        let columns = ElasticsearchMappingFlattener.flattenMapping(properties: properties)
        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
        #expect(byName["orders"]?.nestedPaths.isEmpty == true)
        #expect(byName["orders.ref"]?.nestedPaths == ["orders"])
        #expect(byName["orders.items"]?.nestedPaths == ["orders"])
        #expect(byName["orders.items.sku"]?.nestedPaths == ["orders", "orders.items"])
        #expect(ElasticsearchMappingFlattener.nestedParents(from: columns) == ["orders", "orders.items"])
    }
}

struct ElasticsearchStatementGeneratorTests {
    private func generator() -> ElasticsearchStatementGenerator {
        ElasticsearchStatementGenerator(
            index: "users",
            columns: ["_id", "_index", "_score", "name", "age"],
            columnTypeNames: ["keyword", "keyword", "float", "text", "long"]
        )
    }

    @Test("Update encodes a POST _update keyed by _id")
    func updateRequest() {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 3, columnName: "name", oldValue: .text("Bob"), newValue: .text("Alice"))],
            originalRow: [.text("doc1"), .text("users"), .text("1"), .text("Bob"), .text("30")]
        )
        let statements = generator().generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        #expect(statements.count == 1)
        let decoded = ElasticsearchStatementGenerator.decode(statements[0].statement)
        #expect(decoded?.method == "POST")
        #expect(decoded?.path.contains("/users/_update/doc1") == true)
        #expect(decoded?.body?.contains("Alice") == true)
    }

    @Test("Delete encodes a DELETE _doc by _id")
    func deleteRequest() {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: [.text("doc9"), .text("users"), .text("1"), .text("Bob"), .text("30")]
        )
        let statements = generator().generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        let decoded = ElasticsearchStatementGenerator.decode(statements[0].statement)
        #expect(decoded?.method == "DELETE")
        #expect(decoded?.path.contains("/users/_doc/doc9") == true)
    }

    @Test("Insert coerces numeric fields and omits meta columns")
    func insertRequest() {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let statements = generator().generateStatements(
            from: [change],
            insertedRowData: [0: [.null, .null, .null, .text("Eve"), .text("25")]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        let decoded = ElasticsearchStatementGenerator.decode(statements[0].statement)
        #expect(decoded?.method == "POST")
        #expect(decoded?.path.contains("/users/_doc") == true)
        #expect(decoded?.body?.contains("\"age\":25") == true)
        #expect(decoded?.body?.contains("_index") == false)
    }

    private func nestedGenerator() -> ElasticsearchStatementGenerator {
        ElasticsearchStatementGenerator(
            index: "persons",
            columns: ["_id", "identifiers", "identifiers.type", "personId"],
            columnTypeNames: ["keyword", "nested", "keyword", "keyword"]
        )
    }

    @Test("Insert writes the nested array once, through its parent column")
    func insertOmitsNestedLeaves() {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let statements = nestedGenerator().generateStatements(
            from: [change],
            insertedRowData: [0: [
                .null,
                .text("[{\"type\":\"CPF\"}]"),
                .text("[\"CPF\"]"),
                .text("p1"),
            ]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        let body = ElasticsearchStatementGenerator.decode(statements[0].statement)?.body
        #expect(body?.contains("\"identifiers\":[{\"type\":\"CPF\"}]") == true)
        #expect(body?.contains("identifiers.type") == false)
    }

    @Test("Update skips a nested leaf edit and keeps the rest of the row")
    func updateSkipsNestedLeaf() {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (
                    columnIndex: 2, columnName: "identifiers.type",
                    oldValue: .text("[\"CPF\"]"), newValue: .text("[\"X\"]")
                ),
                (columnIndex: 3, columnName: "personId", oldValue: .text("p1"), newValue: .text("p2")),
            ],
            originalRow: [.text("doc1"), .text("[]"), .text("[\"CPF\"]"), .text("p1")]
        )
        let statements = nestedGenerator().generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        let body = ElasticsearchStatementGenerator.decode(statements[0].statement)?.body
        #expect(body?.contains("identifiers.type") == false)
        #expect(body?.contains("p2") == true)
    }

    @Test("Insert with explicit _id uses PUT")
    func insertWithId() {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let statements = generator().generateStatements(
            from: [change],
            insertedRowData: [0: [.text("custom"), .null, .null, .text("Eve"), .text("25")]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        let decoded = ElasticsearchStatementGenerator.decode(statements[0].statement)
        #expect(decoded?.method == "PUT")
        #expect(decoded?.path.contains("/users/_doc/custom") == true)
    }

    @Test("Document id with a slash is percent-encoded into one path segment")
    func slashInDocumentId() {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: [.text("tenant/123"), .text("users"), .text("1"), .text("Bob"), .text("30")]
        )
        let statements = generator().generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        let decoded = ElasticsearchStatementGenerator.decode(statements[0].statement)
        #expect(decoded?.path.contains("/users/_doc/tenant%2F123") == true)
    }

    @Test("Insert preserves an intentional empty string")
    func insertKeepsEmptyString() {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let statements = generator().generateStatements(
            from: [change],
            insertedRowData: [0: [.null, .null, .null, .text(""), .text("25")]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        let decoded = ElasticsearchStatementGenerator.decode(statements[0].statement)
        #expect(decoded?.body?.contains("\"name\":\"\"") == true)
    }

    @Test("JSON object text is kept as a string on a scalar field")
    func jsonObjectKeptAsStringOnScalarField() {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let statements = generator().generateStatements(
            from: [change],
            insertedRowData: [0: [.null, .null, .null, .text("{\"a\":1}"), .text("25")]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        let decoded = ElasticsearchStatementGenerator.decode(statements[0].statement)
        #expect(decoded?.body?.contains("\"name\":\"{\\\"a\\\":1}\"") == true)
    }
}
