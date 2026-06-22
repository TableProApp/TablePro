//
//  ElasticsearchDriverTests.swift
//  TableProTests
//
//  Tests for Elasticsearch plugin pure logic (compiled via symlinks from ElasticsearchDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Elasticsearch - Console Parser")
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

@Suite("Elasticsearch - Query Builder Encoding")
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
            filters: [(column: "age", op: ">", value: "21")],
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

@Suite("Elasticsearch - Query DSL")
struct ElasticsearchQueryDSLTests {
    private let textField = ["title": ElasticsearchFieldInfo(type: "text", hasKeywordSubfield: true)]
    private let keywordField = ["status": ElasticsearchFieldInfo(type: "keyword", hasKeywordSubfield: false)]
    private let numericField = ["age": ElasticsearchFieldInfo(type: "long", hasKeywordSubfield: false)]

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

    @Test("IS NULL becomes must_not exists")
    func isNull() {
        let filter = ElasticsearchFilterSpec(column: "status", op: "IS NULL", value: "")
        let clause = ElasticsearchQueryBuilder.clause(for: filter, fields: keywordField)
        let bool = clause["bool"] as? [String: Any]
        #expect((bool?["should"] as? [[String: Any]])?.count == 2)
        #expect(bool?["minimum_should_match"] as? Int == 1)
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

    @Test("case_insensitive is omitted when unsupported (pre-7.10)")
    func caseInsensitiveGated() {
        let on = ElasticsearchQueryBuilder.clause(
            for: ElasticsearchFilterSpec(column: "status", op: "CONTAINS", value: "x"),
            fields: keywordField, caseInsensitive: true
        )
        #expect((on["wildcard"] as? [String: Any]).map { ($0["status"] as? [String: Any])?["case_insensitive"] as? Bool } == true)
        let off = ElasticsearchQueryBuilder.clause(
            for: ElasticsearchFilterSpec(column: "status", op: "CONTAINS", value: "x"),
            fields: keywordField, caseInsensitive: false
        )
        let offOptions = (off["wildcard"] as? [String: Any])?["status"] as? [String: Any]
        #expect(offOptions?["case_insensitive"] == nil)
    }
}

@Suite("Elasticsearch - Appended ORDER BY")
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

@Suite("Elasticsearch - Mapping Flattener")
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
}

@Suite("Elasticsearch - Statement Generator")
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
