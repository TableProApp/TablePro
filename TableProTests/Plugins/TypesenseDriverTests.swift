//
//  TypesenseDriverTests.swift
//  TableProTests
//
//  Tests for Typesense plugin pure logic (compiled from TypesenseDriverPlugin sources).
//

import Foundation
import TableProPluginKit
import Testing

private func field(
    _ name: String,
    _ type: String,
    sortable: Bool = false,
    optional: Bool = false,
    facet: Bool = false
) -> TypesenseField {
    TypesenseField(name: name, type: type, isSortable: sortable, isOptional: optional, isFacet: facet)
}

private let booksFields: [String: TypesenseField] = [
    "id": TypesenseSchema.idField,
    "title": field("title", "string"),
    "authors": field("authors", "string[]", facet: true),
    "year": field("year", "int32", sortable: true),
    "rating": field("rating", "float", sortable: true),
    "inprint": field("inprint", "bool", sortable: true),
    "tag": field("tag", "string", sortable: true, optional: true),
]

@Suite("Typesense - Console Parser")
struct TypesenseConsoleParserTests {
    @Test("Parses method, path, and JSON body")
    func parsesFullRequest() {
        let input = "POST /multi_search\n{\n  \"searches\": []\n}"
        let request = TypesenseConsoleParser.parse(input)
        #expect(request?.method == "POST")
        #expect(request?.path == "/multi_search")
        #expect(request?.body?.contains("searches") == true)
    }

    @Test("Normalizes a path without a leading slash")
    func normalizesPath() {
        let request = TypesenseConsoleParser.parse("GET collections/books/documents/search?q=*")
        #expect(request?.method == "GET")
        #expect(request?.path == "/collections/books/documents/search?q=*")
        #expect(request?.body == nil)
    }

    @Test("Lowercase method is normalized and PATCH is supported")
    func normalizesMethods() {
        #expect(TypesenseConsoleParser.parse("get /collections")?.method == "GET")
        #expect(TypesenseConsoleParser.parse("patch /collections/a/documents/1\n{}")?.method == "PATCH")
    }

    @Test("Rejects an unsupported method and empty input")
    func rejectsUnknownMethod() {
        #expect(TypesenseConsoleParser.parse("FETCH /collections") == nil)
        #expect(TypesenseConsoleParser.parse("") == nil)
    }

    /// `DELETE FROM books` shares its first word with an HTTP verb. Measured before the guard: the
    /// parser read `FROM books` as a path and the driver sent a real `DELETE` to `/FROM books`.
    @Test("SQL that starts with an HTTP verb is not read as a request")
    func rejectsSQLWearingAVerb() {
        #expect(TypesenseConsoleParser.parse("DELETE FROM books") == nil)
        #expect(TypesenseConsoleParser.parse("DELETE FROM books WHERE id = 1") == nil)
        #expect(TypesenseConsoleParser.parse("GET rows FROM books") == nil)
    }

    /// A query string may hold a space, so the guard only looks at the path.
    @Test("A space inside the query string is still accepted")
    func keepsSpacesInQueryStrings() {
        let request = TypesenseConsoleParser.parse("GET /collections/books/documents/search?q=hello world")
        #expect(request?.path == "/collections/books/documents/search?q=hello world")
    }
}

@Suite("Typesense - Schema")
struct TypesenseSchemaTests {
    private let response: [String: Any] = [
        "name": "books",
        "num_documents": 42,
        "default_sorting_field": "year",
        "fields": [
            ["name": ".*", "type": "auto", "sort": false, "optional": true],
            ["name": "title", "type": "string", "sort": false, "optional": false],
            ["name": "year", "type": "int32", "sort": true, "optional": false],
            ["name": "meta", "type": "object", "sort": false, "optional": true],
            ["name": "meta.pages", "type": "int64", "sort": true, "optional": true],
            ["name": "notes", "type": "object", "sort": false, "optional": true],
        ],
    ]

    @Test("Decodes name, document count and default sorting field")
    func decodesCollection() throws {
        let collection = try #require(TypesenseSchema.collection(from: response))
        #expect(collection.name == "books")
        #expect(collection.numDocuments == 42)
        #expect(collection.defaultSortingField == "year")
    }

    @Test("The auto-schema wildcard entry is never a column")
    func dropsWildcardField() throws {
        let collection = try #require(TypesenseSchema.collection(from: response))
        #expect(!collection.presentedFields.contains { $0.name == TypesenseSchema.wildcardField })
    }

    @Test("An object parent gives way to its dotted leaves, and survives when it has none")
    func dropsObjectParentsThatHaveLeaves() throws {
        let collection = try #require(TypesenseSchema.collection(from: response))
        let names = collection.presentedFields.map(\.name)
        #expect(!names.contains("meta"))
        #expect(names.contains("meta.pages"))
        #expect(names.contains("notes"))
    }

    @Test("id leads the columns and is never a schema field")
    func idLeadsTheColumns() throws {
        let collection = try #require(TypesenseSchema.collection(from: response))
        #expect(collection.columns.first == "id")
        #expect(!collection.presentedFields.contains { $0.name == "id" })
        #expect(collection.fieldsByName["id"]?.isSortable == false)
    }

    @Test("An empty default_sorting_field decodes as absent")
    func emptyDefaultSortDecodesAsNil() throws {
        let collection = try #require(
            TypesenseSchema.collection(from: ["name": "c", "default_sorting_field": "", "fields": []])
        )
        #expect(collection.defaultSortingField == nil)
    }

    @Test("Nested documents flatten onto dotted columns")
    func flattensNestedDocuments() {
        let documents: [[String: Any]] = [
            ["id": "a1", "title": "Dune", "meta": ["pages": 412]],
        ]
        let rows = TypesenseSchema.rows(for: documents, columns: ["id", "title", "meta.pages"])
        #expect(rows == [[.text("a1"), .text("Dune"), .text("412")]])
    }

    @Test("A missing value is null, and arrays and objects render as JSON")
    func rendersMissingAndCompositeValues() {
        let documents: [[String: Any]] = [["id": "a1", "authors": ["Tolkien", "Lewis"]]]
        let rows = TypesenseSchema.rows(for: documents, columns: ["id", "authors", "title"])
        #expect(rows[0][0] == .text("a1"))
        #expect(rows[0][1] == .text("[\"Tolkien\",\"Lewis\"]"))
        #expect(rows[0][2] == .null)
    }

    /// Typesense reports an `object[]` field as its dotted leaves and returns the document with
    /// the array intact, so a column named `variants.sku` has to read across the array's elements.
    @Test("A dotted column over an object array collects a value from each element")
    func readsAcrossObjectArrays() {
        let documents: [[String: Any]] = [[
            "id": "1",
            "variants": [["sku": "A1", "qty": 3], ["sku": "B2", "qty": 5]],
        ]]
        let rows = TypesenseSchema.rows(for: documents, columns: ["id", "variants.sku", "variants.qty"])
        #expect(rows[0][0] == .text("1"))
        #expect(rows[0][1] == .text("[\"A1\",\"B2\"]"))
        #expect(rows[0][2] == .text("[3,5]"))
    }

    @Test("An element missing the leaf contributes nothing, and no element means null")
    func objectArrayLeavesTolerateGaps() {
        let documents: [[String: Any]] = [
            ["variants": [["sku": "A1"], ["qty": 9]]],
            ["variants": [["qty": 9]]],
            ["variants": []],
        ]
        let rows = TypesenseSchema.rows(for: documents, columns: ["variants.sku"])
        #expect(rows[0][0] == .text("[\"A1\"]"))
        #expect(rows[1][0] == .null)
        #expect(rows[2][0] == .null)
    }

    @Test("A deeper path still walks through an array on the way")
    func readsThroughNestedObjectArrays() {
        let documents: [[String: Any]] = [[
            "variants": [["price": ["eur": 10]], ["price": ["eur": 20]]],
        ]]
        let rows = TypesenseSchema.rows(for: documents, columns: ["variants.price.eur"])
        #expect(rows[0][0] == .text("[10,20]"))
    }

    @Test("The schema drops an object array parent that has dotted leaves")
    func dropsObjectArrayParents() {
        let fields = [
            TypesenseField(name: "variants", type: "object[]", isSortable: false, isOptional: true, isFacet: false),
            TypesenseField(name: "variants.sku", type: "string[]", isSortable: false, isOptional: true, isFacet: false),
        ]
        #expect(TypesenseSchema.presentedFields(fields).map(\.name) == ["variants.sku"])
    }

    @Test("Booleans render as true and false, not 1 and 0")
    func rendersBooleans() {
        let rows = TypesenseSchema.rows(for: [["inprint": true]], columns: ["inprint"])
        #expect(rows == [[.text("true")]])
    }

    @Test("Union columns put id first and sort the rest")
    func unionColumnsLeadWithId() {
        let columns = TypesenseSchema.unionColumns(fromDocuments: [
            ["zeta": 1, "id": "x"],
            ["alpha": 2],
        ])
        #expect(columns == ["id", "alpha", "zeta"])
    }
}

@Suite("Typesense - Filter Builder")
struct TypesenseFilterBuilderTests {
    private func clause(_ column: String, _ op: String, _ value: String, second: String? = nil) throws -> String {
        try TypesenseFilterBuilder.clause(
            for: TypesenseFilterSpec(column: column, op: op, value: value, secondValue: second),
            fields: booksFields
        )
    }

    @Test("A string value is backticked and a numeric one is not")
    func quotesByFieldType() throws {
        #expect(try clause("title", "=", "The Hobbit") == "title:=`The Hobbit`")
        #expect(try clause("year", "=", "1965") == "year:=1965")
        #expect(try clause("inprint", "=", "TRUE") == "inprint:=true")
        #expect(try clause("id", "=", "a1") == "id:=`a1`")
    }

    @Test("Equality, negation, membership and prefix take their Typesense shapes")
    func buildsOperatorShapes() throws {
        #expect(try clause("tag", "!=", "cyber") == "tag:!=`cyber`")
        #expect(try clause("tag", "IN", "cyber, scifi") == "tag:=[`cyber`,`scifi`]")
        #expect(try clause("tag", "NOT IN", "cyber, scifi") == "tag:!=[`cyber`,`scifi`]")
        #expect(try clause("title", "CONTAINS", "hobbit") == "title:`hobbit`")
        #expect(try clause("title", "NOT CONTAINS", "hobbit") == "title:!`hobbit`")
        #expect(try clause("title", "STARTS WITH", "Neuro") == "title:`Neuro`*")
    }

    @Test("Comparisons are numeric and BETWEEN reads its upper bound off the filter")
    func buildsNumericComparisons() throws {
        #expect(try clause("year", ">", "1900") == "year:>1900")
        #expect(try clause("year", ">=", "1900") == "year:>=1900")
        #expect(try clause("rating", "<", "4.5") == "rating:<4.5")
        #expect(try clause("year", "BETWEEN", "1937", second: "1965") == "year:[1937..1965]")
    }

    @Test("A comparison on a string field is refused rather than silently matching nothing")
    func refusesStringComparison() {
        #expect(throws: TypesenseFilterError.comparisonNeedsNumber(column: "title", op: ">")) {
            try clause("title", ">", "D")
        }
    }

    @Test("A comparison against non-numeric text is refused")
    func refusesNonNumericComparison() {
        #expect(throws: TypesenseFilterError.comparisonNeedsNumber(column: "year", op: ">")) {
            try clause("year", ">", "soon")
        }
    }

    @Test("BETWEEN without an upper bound is refused")
    func refusesBetweenWithoutUpperBound() {
        #expect(throws: TypesenseFilterError.missingUpperBound(column: "year")) {
            try clause("year", "BETWEEN", "1937")
        }
    }

    @Test("Operators Typesense cannot express are refused by name")
    func refusesUnsupportedOperators() {
        for op in ["IS NULL", "IS NOT NULL", "IS EMPTY", "IS NOT EMPTY", "REGEX", "ENDS WITH"] {
            #expect(throws: TypesenseFilterError.unsupportedOperator(op), "\(op)") {
                try clause("title", op, "x")
            }
        }
    }

    /// The reason the guard exists: Typesense has no escape for a backtick, so a value carrying one
    /// closes its literal and the rest of the value is parsed as filter syntax. Measured on 29.0,
    /// this exact payload matched every document in the collection.
    @Test("A backtick in a value is refused instead of injecting filter syntax")
    func refusesBacktickInjection() {
        #expect(throws: TypesenseFilterError.backtickInValue(column: "tag")) {
            try clause("tag", "=", "odd` || year:>0")
        }
        #expect(throws: TypesenseFilterError.backtickInValue(column: "tag")) {
            try clause("tag", "IN", "safe, odd` || year:>0")
        }
        #expect(throws: TypesenseFilterError.backtickInValue(column: "title")) {
            try clause("title", "CONTAINS", "a`b")
        }
    }

    @Test("A backtick in a numeric field's value never reaches a literal")
    func numericFieldRejectsInjectionThroughComparison() {
        #expect(throws: TypesenseFilterError.comparisonNeedsNumber(column: "year", op: ">")) {
            try clause("year", ">", "1900` || year:>0")
        }
    }

    /// A numeric or boolean value is sent unquoted, so it carries no delimiter of its own: without
    /// a parse check, `year:=1900 || year:>0` reaches the server as filter syntax. The field type
    /// that picks the unquoted branch is declared by the server, so the check cannot be skipped.
    @Test("An unquoted numeric value must parse as a number, on every operator that sends one")
    func numericLiteralsAreValidated() {
        let injection = "1900 || year:>0"
        #expect(throws: TypesenseFilterError.notANumber(column: "year", value: injection)) {
            try clause("year", "=", injection)
        }
        #expect(throws: TypesenseFilterError.notANumber(column: "year", value: injection)) {
            try clause("year", "!=", injection)
        }
        #expect(throws: TypesenseFilterError.notANumber(column: "year", value: injection)) {
            try clause("year", "IN", "1,\(injection)")
        }
        #expect(throws: TypesenseFilterError.notANumber(column: "year", value: injection)) {
            try clause("year", "NOT IN", "1,\(injection)")
        }
    }

    @Test("An unquoted boolean value must be true or false")
    func booleanLiteralsAreValidated() throws {
        #expect(throws: TypesenseFilterError.notABoolean(column: "inprint", value: "true || year:>0")) {
            try clause("inprint", "=", "true || year:>0")
        }
        #expect(try clause("inprint", "=", "FALSE") == "inprint:=false")
    }

    @Test("A well-formed number or boolean still goes over unquoted")
    func validUnquotedLiteralsSurvive() throws {
        #expect(try clause("year", "=", "1965") == "year:=1965")
        #expect(try clause("rating", "=", "4.5") == "rating:=4.5")
        #expect(try clause("year", "=", "-3") == "year:=-3")
        #expect(try clause("year", "IN", "1937, 1965") == "year:=[1937,1965]")
        #expect(try clause("inprint", "!=", "true") == "inprint:!=true")
    }

    @Test("An unknown field is quoted as text so it cannot carry an injection either")
    func quotesUnknownFieldsAsText() throws {
        let clause = try TypesenseFilterBuilder.clause(
            for: TypesenseFilterSpec(column: "learned", op: "=", value: "value"),
            fields: booksFields
        )
        #expect(clause == "learned:=`value`")
    }

    /// Typesense matches strings without regard to case and offers no option to change that, so
    /// the driver must not build a different clause when the filter row asks for one.
    @Test("The case setting never changes the clause, because Typesense cannot honour it")
    func caseSettingDoesNotChangeTheClause() throws {
        for op in ["=", "!=", "CONTAINS", "NOT CONTAINS", "STARTS WITH", "IN"] {
            let sensitive = PluginQueryFilter(column: "tag", op: op, value: "Cyber", isCaseSensitive: true)
            let insensitive = PluginQueryFilter(column: "tag", op: op, value: "Cyber", isCaseSensitive: false)
            let first = try TypesenseFilterBuilder.clause(
                for: TypesenseFilterSpec(sensitive), fields: booksFields
            )
            let second = try TypesenseFilterBuilder.clause(
                for: TypesenseFilterSpec(insensitive), fields: booksFields
            )
            #expect(first == second, "\(op)")
        }
    }

    @Test("Several filters are parenthesised and joined by the logic mode")
    func joinsClauses() throws {
        let filters = [
            TypesenseFilterSpec(column: "year", op: ">", value: "1900"),
            TypesenseFilterSpec(column: "tag", op: "=", value: "cyber"),
        ]
        let and = try TypesenseFilterBuilder.expression(
            filters: filters, logicMode: "AND", fields: booksFields
        )
        let or = try TypesenseFilterBuilder.expression(
            filters: filters, logicMode: "OR", fields: booksFields
        )
        #expect(and == "(year:>1900) && (tag:=`cyber`)")
        #expect(or == "(year:>1900) || (tag:=`cyber`)")
    }

    @Test("A single filter is not parenthesised, and no filters means no filter_by")
    func singleAndEmptyExpressions() throws {
        let single = try TypesenseFilterBuilder.expression(
            filters: [TypesenseFilterSpec(column: "year", op: "=", value: "1965")],
            logicMode: "AND",
            fields: booksFields
        )
        #expect(single == "year:=1965")
        #expect(try TypesenseFilterBuilder.expression(filters: [], logicMode: "AND", fields: [:]) == nil)
    }

    @Test("The raw filter row is passed through verbatim, and an empty one is dropped")
    func rawColumnPassesThrough() throws {
        let raw = try TypesenseFilterBuilder.expression(
            filters: [TypesenseFilterSpec(column: TypesenseFilterBuilder.rawColumn, op: "=", value: "year:>1900")],
            logicMode: "AND",
            fields: booksFields
        )
        #expect(raw == "year:>1900")

        let blank = try TypesenseFilterBuilder.expression(
            filters: [TypesenseFilterSpec(column: TypesenseFilterBuilder.rawColumn, op: "=", value: "  ")],
            logicMode: "AND",
            fields: booksFields
        )
        #expect(blank == nil)
    }
}

@Suite("Typesense - Query Builder")
struct TypesenseQueryBuilderTests {
    @Test("A tagged search round-trips through its encoding")
    func taggedSearchRoundTrips() throws {
        let query = TypesenseQueryBuilder.encodeSearch(
            collection: "books",
            offset: 250,
            limit: 1_000,
            sorts: [TypesenseSortSpec(column: "year", ascending: false)],
            filters: [TypesenseFilterSpec(column: "tag", op: "=", value: "cyber")],
            logicMode: "OR"
        )
        #expect(TypesenseQueryBuilder.isTaggedQuery(query))
        let parsed = try #require(TypesenseQueryBuilder.parseSearch(query))
        #expect(parsed.collection == "books")
        #expect(parsed.offset == 250)
        #expect(parsed.limit == 1_000)
        #expect(parsed.sorts == [TypesenseSortSpec(column: "year", ascending: false)])
        #expect(parsed.filters == [TypesenseFilterSpec(column: "tag", op: "=", value: "cyber")])
        #expect(parsed.logicMode == "OR")
    }

    @Test("A collection name with a colon survives the encoding")
    func encodesAwkwardCollectionNames() throws {
        let query = TypesenseQueryBuilder.encodeSearch(
            collection: "a:b:c", offset: 0, limit: 10, sorts: [], filters: [], logicMode: "AND"
        )
        let parsed = try #require(TypesenseQueryBuilder.parseSearch(query))
        #expect(parsed.collection == "a:b:c")
    }

    @Test("An appended ORDER BY is split off and parsed")
    func extractsAppendedOrderBy() {
        let base = TypesenseQueryBuilder.encodeSearch(
            collection: "books", offset: 0, limit: 10, sorts: [], filters: [], logicMode: "AND"
        )
        let (stripped, sorts) = TypesenseQueryBuilder.extractOrderBy("\(base) ORDER BY \"year\" DESC, tag ASC")
        #expect(stripped == base)
        #expect(sorts == [
            TypesenseSortSpec(column: "year", ascending: false),
            TypesenseSortSpec(column: "tag", ascending: true),
        ])
    }

    /// Sorting a field whose schema says `sort: false` is a 400 that fails the whole search.
    @Test("Only sortable fields reach sort_by, and id never does")
    func dropsUnsortableColumns() {
        let sorts = [
            TypesenseSortSpec(column: "title", ascending: true),
            TypesenseSortSpec(column: "id", ascending: true),
            TypesenseSortSpec(column: "year", ascending: false),
        ]
        #expect(TypesenseQueryBuilder.sortBy(sorts, fields: booksFields) == "year:desc")
    }

    @Test("No sortable column means no sort_by at all")
    func noSortableColumnsMeansNoClause() {
        let sorts = [TypesenseSortSpec(column: "title", ascending: true)]
        #expect(TypesenseQueryBuilder.sortBy(sorts, fields: booksFields) == nil)
    }

    @Test("sort_by stops at three fields")
    func capsSortFieldsAtThree() {
        let sorts = [
            TypesenseSortSpec(column: "year", ascending: true),
            TypesenseSortSpec(column: "rating", ascending: false),
            TypesenseSortSpec(column: "tag", ascending: true),
            TypesenseSortSpec(column: "inprint", ascending: false),
        ]
        #expect(TypesenseQueryBuilder.sortBy(sorts, fields: booksFields) == "year:asc,rating:desc,tag:asc")
    }

    @Test("A page larger than 250 rows is split into requests Typesense accepts")
    func splitsPagesAtTheHitCeiling() {
        #expect(TypesenseQueryBuilder.chunks(offset: 0, limit: 1_000) == [
            TypesenseSearchChunk(offset: 0, limit: 250),
            TypesenseSearchChunk(offset: 250, limit: 250),
            TypesenseSearchChunk(offset: 500, limit: 250),
            TypesenseSearchChunk(offset: 750, limit: 250),
        ])
    }

    @Test("A page inside the ceiling is one request, and the offset is carried")
    func smallPagesAreOneRequest() {
        #expect(TypesenseQueryBuilder.chunks(offset: 40, limit: 100) == [
            TypesenseSearchChunk(offset: 40, limit: 100),
        ])
    }

    @Test("A remainder chunk asks only for what is left")
    func lastChunkAsksForTheRemainder() {
        let chunks = TypesenseQueryBuilder.chunks(offset: 0, limit: 600)
        #expect(chunks.count == 3)
        #expect(chunks.last == TypesenseSearchChunk(offset: 500, limit: 100))
    }

    @Test("A non-positive limit asks for nothing")
    func nonPositiveLimitsAskForNothing() {
        #expect(TypesenseQueryBuilder.chunks(offset: 0, limit: 0).isEmpty)
        #expect(TypesenseQueryBuilder.chunks(offset: 0, limit: -5).isEmpty)
    }

    /// The 51st search in one multi_search answers 400 for the whole batch.
    @Test("Searches are batched at the multi_search ceiling")
    func batchesAtTheMultiSearchCeiling() {
        let chunks = TypesenseQueryBuilder.chunks(offset: 0, limit: 100_000)
        let batches = TypesenseQueryBuilder.batches(chunks)
        #expect(chunks.count == 400)
        #expect(batches.count == 8)
        #expect(batches.allSatisfy { $0.count <= TypesenseQueryBuilder.maxSearchesPerRequest })
        #expect(batches.flatMap { $0 } == chunks)
    }

    @Test("A search body names its collection and carries only the parameters it has")
    func buildsSearchBodies() {
        let body = TypesenseQueryBuilder.searchBody(
            collection: "books",
            chunk: TypesenseSearchChunk(offset: 10, limit: 25),
            filterBy: "year:>1900",
            sortBy: nil
        )
        #expect(body["collection"] as? String == "books")
        #expect(body["q"] as? String == "*")
        #expect(body["offset"] as? Int == 10)
        #expect(body["limit"] as? Int == 25)
        #expect(body["filter_by"] as? String == "year:>1900")
        #expect(body["sort_by"] == nil)
    }

    @Test("A count body asks for no hits at all")
    func buildsCountBodies() {
        let body = TypesenseQueryBuilder.countBody(collection: "books", filterBy: nil)
        #expect(body["per_page"] as? Int == 0)
        #expect(body["filter_by"] == nil)
    }
}

@Suite("Typesense - Collection Operations")
struct TypesenseOperationsTests {
    /// Without these the app composes its own SQL and sends it to `execute`. Measured before the
    /// fix: exporting sent `SELECT * FROM c`, dropping sent `DROP TABLE c` and truncating sent
    /// `DELETE FROM c`; the first two were refused by the console parser and the third reached the
    /// server as a real HTTP `DELETE /FROM c`.
    @Test("An export query round-trips the collection name")
    func exportRoundTrips() throws {
        let query = TypesenseOperations.encodeExport(collection: "books")
        #expect(query.hasPrefix(TypesenseOperations.exportTag))
        #expect(TypesenseOperations.decodeExport(query) == "books")
        #expect(TypesenseOperations.decodeExport("GET /collections") == nil)
        #expect(TypesenseOperations.decodeExport(TypesenseOperations.exportTag) == nil)
    }

    @Test("A collection name with a slash stays one segment in the export path")
    func exportPathEncodesTheName() {
        #expect(TypesenseOperations.exportPath(collection: "a/b") == "/collections/a%2Fb/documents/export")
    }

    @Test("Dropping a collection is a DELETE on the collection itself")
    func dropsACollection() throws {
        let request = try #require(TypesenseOperations.dropCollection(named: "books", objectType: "TABLE"))
        #expect(request.method == "DELETE")
        #expect(request.path == "/collections/books")
        #expect(request.body == nil)
    }

    /// Typesense has no databases, views or schemas, so there is no request to send for one and
    /// the app keeps whatever fallback it had.
    @Test("Only a collection can be dropped")
    func refusesToDropOtherObjects() {
        #expect(TypesenseOperations.dropCollection(named: "x", objectType: "VIEW") == nil)
        #expect(TypesenseOperations.dropCollection(named: "x", objectType: "DATABASE") == nil)
        #expect(TypesenseOperations.dropCollection(named: "x", objectType: "COLLECTION") != nil)
    }

    /// `truncate=true` keeps the schema. Deleting by a match-everything filter would take the
    /// learned fields with it.
    @Test("Truncating empties the documents and keeps the collection")
    func truncatesWithTheTruncateFlag() {
        let request = TypesenseOperations.truncateCollection(named: "books")
        #expect(request.method == "DELETE")
        #expect(request.path == "/collections/books/documents?truncate=true")
    }

    @Test("Compact maps to its endpoint, and an operation from another engine is refused")
    func mapsMaintenanceOperations() throws {
        let request = try #require(TypesenseOperations.maintenance("Compact Database"))
        #expect(request.method == "POST")
        #expect(request.path == "/operations/db/compact")
        #expect(TypesenseOperations.maintenance("VACUUM") == nil)
        #expect(TypesenseOperations.maintenance("compact database") != nil)
    }
}

@Suite("Typesense - API Keys")
struct TypesenseApiKeysTests {
    private let payload: [String: Any] = [
        "keys": [
            [
                "id": 0,
                "description": "Search-only key",
                "actions": ["documents:search"],
                "collections": ["books"],
                "value_prefix": "JrJX",
            ],
            ["id": 7, "description": "", "actions": ["*"], "collections": ["*"]],
        ],
    ]

    @Test("Keys decode, and a key with no description still gets a name")
    func decodesKeys() throws {
        let keys = TypesenseApiKeys.keys(from: payload)
        #expect(keys.count == 2)
        #expect(keys[0].displayName == "Search-only key (#0)")
        #expect(keys[1].displayName == "Key #7")
        #expect(keys[0].valuePrefix == "JrJX")
    }

    /// `PluginPrincipalRef` carries only a name, so the key id has to survive inside it.
    @Test("The key id survives the round trip through the principal name")
    func idRoundTripsThroughTheName() {
        let keys = TypesenseApiKeys.keys(from: payload)
        for key in keys {
            #expect(TypesenseApiKeys.id(fromDisplayName: key.displayName) == key.id)
        }
        #expect(TypesenseApiKeys.id(fromDisplayName: "nonsense") == nil)
    }

    @Test("A key's actions and collections become one grant per pair")
    func projectsGrants() {
        let keys = TypesenseApiKeys.keys(from: payload)
        let scoped = TypesenseApiKeys.grants(for: keys[0], database: "default")
        #expect(scoped.count == 1)
        #expect(scoped[0].privilege == "documents:search")
        #expect(scoped[0].scope == .table(database: "default", schema: nil, table: "books"))

        let wildcard = TypesenseApiKeys.grants(for: keys[1], database: "default")
        #expect(wildcard.map(\.scope) == [.server])
    }

    @Test("A create request carries the description, actions and collections")
    func buildsACreateRequest() throws {
        let request = try #require(TypesenseApiKeys.createRequest(
            description: "Reader", actions: ["documents:search"], collections: ["books"]
        ))
        #expect(request.method == "POST")
        #expect(request.path == "/keys")
        #expect(request.body == #"{"actions":["documents:search"],"collections":["books"],"description":"Reader"}"#)
    }

    @Test("An empty collection list means every collection")
    func defaultsToEveryCollection() throws {
        let request = try #require(TypesenseApiKeys.createRequest(
            description: "R", actions: [], collections: []
        ))
        #expect(request.body?.contains(#""collections":["*"]"#) == true)
    }

    @Test("Deleting a key addresses it by id")
    func buildsADeleteRequest() {
        let request = TypesenseApiKeys.deleteRequest(id: 7)
        #expect(request.method == "DELETE")
        #expect(request.path == "/keys/7")
    }
}

@Suite("Typesense - Path Encoding")
struct TypesensePathEncodingTests {
    @Test("A slash never survives into the path, so a segment stays one segment")
    func encodesSlashes() {
        #expect(TypesensePathEncoding.segment("a/b") == "a%2Fb")
    }

    @Test("A dot is encoded, so `.` and `..` cannot act as path segments")
    func encodesDots() {
        #expect(TypesensePathEncoding.segment(".") == "%2E")
        #expect(TypesensePathEncoding.segment("..") == "%2E%2E")
        #expect(TypesensePathEncoding.segment("v1.2") == "v1%2E2")
    }

    @Test("A query or fragment marker is encoded rather than changing the request")
    func encodesQueryAndFragmentMarkers() {
        #expect(TypesensePathEncoding.segment("a?truncate=true") == "a%3Ftruncate=true")
        #expect(TypesensePathEncoding.segment("a#b") == "a%23b")
    }

    @Test("An ordinary id passes through unchanged")
    func leavesOrdinaryIdsAlone() {
        #expect(TypesensePathEncoding.segment("abc-123_x") == "abc-123_x")
    }

    private let base = URL(string: "http://localhost:8108")!

    @Test("An ordinary path resolves against the connection's own base URL")
    func resolvesOrdinaryPaths() throws {
        let url = try #require(TypesensePathEncoding.resolve("/collections", against: base))
        #expect(url.absoluteString == "http://localhost:8108/collections")
    }

    /// `//host` is a network-path reference, so `URL(string:relativeTo:)` reads what follows as a
    /// host. The API key header rides on every request, so this shape would leak it.
    @Test("A path that names another host is refused rather than resolved")
    func refusesPathsThatLeaveTheOrigin() {
        for path in [
            "//attacker.example.com/x",
            "//127.0.0.1:9999/exfil",
            "//user@evil/x",
            "https://attacker.example.com/x",
            "http://localhost:9999/x",
        ] {
            #expect(TypesensePathEncoding.resolve(path, against: base) == nil, "\(path)")
        }
    }

    @Test("A path holding a query string still resolves on the origin")
    func resolvesPathsWithQueries() throws {
        let url = try #require(
            TypesensePathEncoding.resolve("/collections/books/documents/search?q=*", against: base)
        )
        #expect(url.host == "localhost")
        #expect(url.port == 8_108)
    }
}

@Suite("Typesense - Statement Generator")
struct TypesenseStatementGeneratorTests {
    private let columns = ["id", "title", "year", "inprint", "authors"]

    private var generator: TypesenseStatementGenerator {
        TypesenseStatementGenerator(collection: "books", columns: columns, fields: booksFields)
    }

    private func request(_ statements: [(statement: String, parameters: [PluginCellValue])]) throws
        -> TypesenseWriteRequest {
        let first = try #require(statements.first)
        return try #require(TypesenseStatementGenerator.decode(first.statement))
    }

    @Test("An insert posts the document, typed by the collection schema")
    func insertPostsTheDocument() throws {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let statements = generator.generateStatements(
            from: [change],
            insertedRowData: [0: [
                .text("a1"), .text("Dune"), .text("1965"), .text("true"), .text("[\"Herbert\"]"),
            ]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        let request = try request(statements)
        #expect(request.method == "POST")
        #expect(request.path == "/collections/books/documents")
        #expect(request.body == #"{"authors":["Herbert"],"id":"a1","inprint":true,"title":"Dune","year":1965}"#)
    }

    @Test("A blank id is left out so Typesense assigns one")
    func insertOmitsABlankId() throws {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let statements = generator.generateStatements(
            from: [change],
            insertedRowData: [0: [.text(""), .text("Dune"), .null, .null, .null]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        let request = try request(statements)
        #expect(request.body == #"{"title":"Dune"}"#)
    }

    @Test("An update patches only the changed fields and never rewrites id")
    func updatePatchesChangedFields() throws {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "title", oldValue: .text("Dune"), newValue: .text("Dune II")),
                (columnIndex: 0, columnName: "id", oldValue: .text("a1"), newValue: .text("zz")),
            ],
            originalRow: [.text("a1"), .text("Dune"), .text("1965"), .text("true"), .null]
        )
        let statements = generator.generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        let request = try request(statements)
        #expect(request.method == "PATCH")
        #expect(request.path == "/collections/books/documents/a1")
        #expect(request.body == #"{"title":"Dune II"}"#)
    }

    @Test("A delete addresses the document by id")
    func deleteAddressesTheDocument() throws {
        let change = PluginRowChange(
            rowIndex: 0, type: .delete, cellChanges: [],
            originalRow: [.text("a1"), .text("Dune"), .null, .null, .null]
        )
        let statements = generator.generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        let request = try request(statements)
        #expect(request.method == "DELETE")
        #expect(request.path == "/collections/books/documents/a1")
        #expect(request.body == nil)
    }

    @Test("An update or delete with no id is skipped rather than guessed at")
    func skipsRowsWithoutAnId() {
        let update = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "title", oldValue: .null, newValue: .text("x"))],
            originalRow: nil
        )
        let delete = PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: [.text("")])
        let statements = generator.generateStatements(
            from: [update, delete], insertedRowData: [:], deletedRowIndices: [1], insertedRowIndices: []
        )
        #expect(statements.isEmpty)
    }

    @Test("A document id needing escaping is percent-encoded into the path")
    func encodesDocumentIdsInPaths() throws {
        let change = PluginRowChange(
            rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.text("a/b c")]
        )
        let statements = generator.generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        let request = try request(statements)
        #expect(request.path == "/collections/books/documents/a%2Fb%20c")
    }

    /// Typesense accepts a document whose id is `..`, and `URL.absoluteURL` resolves a `..`
    /// segment away, so an unencoded dot turns a row delete into a request for the parent path.
    @Test("A dot-only document id is encoded rather than left to resolve as a path segment")
    func encodesRelativePathSegments() throws {
        let change = PluginRowChange(
            rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.text("..")]
        )
        let statements = generator.generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        let request = try request(statements)
        #expect(request.path == "/collections/books/documents/%2E%2E")
        #expect(!request.path.hasSuffix("/.."))
    }

    /// A Typesense collection name is free text and may hold a slash, which addressed
    /// `/collections/a/b` and answered 404 while the collection listed in the sidebar.
    @Test("A collection name with a slash stays one path segment")
    func encodesCollectionNamesInPaths() throws {
        let slashed = TypesenseStatementGenerator(
            collection: "a/b", columns: columns, fields: booksFields
        )
        let change = PluginRowChange(
            rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.text("x")]
        )
        let statements = slashed.generateStatements(
            from: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        let request = try request(statements)
        #expect(request.path == "/collections/a%2Fb/documents/x")
    }

    @Test("A write request round-trips through its tagged encoding")
    func writeRequestRoundTrips() throws {
        let original = TypesenseWriteRequest(
            method: "PATCH", path: "/collections/books/documents/a:1", body: #"{"a":"b:c"}"#
        )
        let encoded = TypesenseStatementGenerator.encode(original)
        #expect(TypesenseStatementGenerator.isTaggedStatement(encoded))
        #expect(TypesenseStatementGenerator.decode(encoded) == original)
    }
}
