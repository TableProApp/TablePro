import Foundation
@testable import TableProMobile
import TableProPluginKit
import Testing

struct MongoDBQueryBuilderTests {
    private func filter(
        _ op: String,
        _ value: String = "4.2",
        column: String = "age",
        isCaseSensitive: Bool = false,
        elementScope: String? = nil,
        builder: MongoDBQueryBuilder = MongoDBQueryBuilder(matchesShownText: true)
    ) -> String {
        builder.buildFilterDocument(from: [PluginQueryFilter(
            column: column, op: op, value: value, isCaseSensitive: isCaseSensitive,
            secondValue: nil, elementScope: elementScope
        )])
    }

    private func regex(_ field: String, _ pattern: String, ignoresCase: Bool = true) -> String {
        let options = ignoresCase ? #", "$options": "i""# : ""
        return #"{"\#(field)": {"$regex": "\#(MongoDBQueryBuilder.escapeJsonString(pattern))"\#(options)}}"#
    }

    @Test("Contains, starts with and ends with match a string by $regex or any value by its shown text", arguments: [
        ("CONTAINS", "4\\.2"), ("STARTS WITH", "^4\\.2"), ("ENDS WITH", "4\\.2$")
    ])
    func patternsReadShownText(op: String, pattern: String) {
        let shown = MongoDBShownText.regexMatch(field: "age", pattern: pattern, ignoresCase: true)
        #expect(filter(op) == #"{"$or": [\#(regex("age", pattern)), \#(shown)]}"#)
    }

    @Test("Not contains keeps only a document whose string and shown text both miss")
    func notContainsReadsShownText() {
        let shown = MongoDBShownText.regexMatch(field: "age", pattern: "4\\.2", ignoresCase: true)
        #expect(filter("NOT CONTAINS") == #"{"$nor": [\#(regex("age", "4\\.2")), \#(shown)]}"#)
    }

    @Test("A pattern ignores case as the filter asks, whatever kind the field was sampled as")
    func patternCaseFollowsTheFilter() {
        let typed = MongoDBQueryBuilder(columnKinds: ["age": .int32], matchesShownText: true)
        #expect(filter("CONTAINS", builder: typed).contains(regex("age", "4\\.2")))
        let sensitive = filter("CONTAINS", isCaseSensitive: true, builder: typed)
        #expect(sensitive.contains(regex("age", "4\\.2", ignoresCase: false)))
        #expect(!sensitive.contains(#""options": "i""#))
    }

    @Test("A condition on one array element matches by $regex alone, since $expr reads only the top-level document")
    func elementScopedPatternHasNoExpression() {
        let scoped = filter("CONTAINS", "x", column: "tags.name", elementScope: "tags")
        #expect(scoped == #"{"tags": {"$elemMatch": {"name": {"$regex": "x", "$options": "i"}}}}"#)
    }

    @Test("A name no aggregation path can read matches by $regex alone, since the path would fail the whole find",
          arguments: ["", "a.", ".b", "c..d", "e.$f"])
    func unreadablePathHasNoExpression(column: String) {
        #expect(!filter("CONTAINS", "x", column: column).contains("$expr"))
        #expect(MongoDBShownText.reads(field: "a.b"))
    }

    @Test("Without $regexMatch a pattern is a $regex alone")
    func patternWithoutShownText() {
        #expect(filter("CONTAINS", builder: MongoDBQueryBuilder()) == regex("age", "4\\.2"))
        #expect(!filter("NOT CONTAINS", builder: MongoDBQueryBuilder()).contains("$expr"))
    }

    @Test("The shown text converts only values that always convert and formats an in-range date as the grid shows it")
    func shownTextExpression() throws {
        let expression = MongoDBShownText.expression(field: "a.b")
        #expect(expression.contains(#""vars": {"v": "$a.b"}"#))
        #expect(expression.contains(#"["double", "int", "long", "decimal", "bool", "objectId"]"#))
        #expect(expression.contains(#"{"$date": {"$numberLong": "-62167219200000"}}"#))
        #expect(expression.contains(#"{"$date": {"$numberLong": "253402300799999"}}"#))
        #expect(expression.contains("%Y-%m-%dT%H:%M:%SZ"))
        #expect(expression.contains("%Y-%m-%dT%H:%M:%S.%LZ"))
        #expect(!expression.contains("$convert"))

        let match = MongoDBShownText.regexMatch(field: #"we"ird"#, pattern: #"a\.b"#, ignoresCase: false)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(match.utf8)) as? [String: Any])
        #expect(parsed["$expr"] != nil)
        #expect(match.contains(#""$we\"ird""#))
        #expect(!match.contains("options"))
    }

    @Test("Under match all a row that cannot be built matches nothing; under match any the other rows still run")
    func unbuildableRowMatchesNothing() {
        let rows = [
            PluginQueryFilter(column: "$where", op: "=", value: "1"),
            PluginQueryFilter(column: "n", op: "=", value: "5")
        ]
        let builder = MongoDBQueryBuilder()
        #expect(builder.buildFilterDocument(from: rows, logicMode: "and") == MongoDBQueryBuilder.impossibleFilter)
        #expect(builder.buildFilterDocument(from: rows, logicMode: "or") == #"{"n": 5}"#)
        #expect(builder.buildFilterDocument(from: [rows[0]], logicMode: "or") == MongoDBQueryBuilder.impossibleFilter)
        let raw = PluginQueryFilter(column: MongoDBQueryBuilder.rawFilterColumn, op: "=", value: "{\"status\": \"a\"")
        #expect(builder.buildFilterDocument(from: [raw, rows[1]]) == MongoDBQueryBuilder.impossibleFilter)
    }

    @Test("A filtered page keeps the kinds of the fields it filtered on, so its count is typed as the page was")
    func filteredPageKeepsItsFieldsKinds() {
        let filter = MongoDBQueryBuilder(columnKinds: ["a": .int32], matchesShownText: true).buildFilterDocument(
            from: [
                PluginQueryFilter(column: "a", op: "!=", value: "1"),
                PluginQueryFilter(column: "b.c", op: "CONTAINS", value: "x", isCaseSensitive: false)
            ],
            logicMode: "and"
        )
        let fields = MongoFilterFields.named(in: filter)
        #expect(fields.isSuperset(of: ["a", "b.c", "b"]))
        #expect(!fields.contains("1"))

        let page: [String: BsonValueKind] = ["a": .string, "b": .document, "n": .string]
        let previous: [String: BsonValueKind] = ["a": .int32, "n": .int32]
        let merged = MongoDBPluginDriver.kinds(page, keepingFrom: previous, of: fields)
        #expect(merged["a"] == .int32)
        #expect(merged["n"] == .string)
        #expect(merged["b"] == nil, "A field the filter read stays unknown when it was unknown before the page")

        let restored = MongoDBPluginDriver.kinds(page, keepingFrom: [:], of: fields)
        #expect(restored["a"] == nil)
        #expect(restored["n"] == .string)

        let scoped = MongoDBQueryBuilder().buildFilterDocument(from: [
            PluginQueryFilter(
                column: "tags.score", op: "!=", value: "1", isCaseSensitive: true, secondValue: nil, elementScope: "tags"
            )
        ])
        let elementFields = MongoFilterFields.named(in: scoped)
        let element = MongoDBPluginDriver.kinds(
            ["tags.score": .string, "other": .string], keepingFrom: ["tags.score": .int32], of: elementFields
        )
        #expect(element["tags.score"] == .int32)
        #expect(element["other"] == .string)
    }

    @Test("Only a find in the session's database with no projection teaches the collection's kinds")
    func storedDocumentsAreOnlyWholeFinds() {
        func outcome(_ find: MongoScriptFindShape?) -> MongoScriptStatementResult {
            var result = MongoScriptStatementResult()
            result.collection = "orders"
            result.find = find
            result.producedDocuments = true
            return result
        }
        let whole = outcome(MongoScriptFindShape(database: "app", returnsWholeDocuments: true, skip: 0))
        #expect(whole.returnsStoredDocuments(in: "app"))
        #expect(!whole.returnsStoredDocuments(in: "other"))
        #expect(!outcome(MongoScriptFindShape(database: "app", returnsWholeDocuments: false, skip: 0))
            .returnsStoredDocuments(in: "app"))
        #expect(!outcome(nil).returnsStoredDocuments(in: "app"))
    }
}
