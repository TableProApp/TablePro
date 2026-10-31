import Foundation
@testable import TableProNeo4jCore
import Testing

struct Neo4jCypherTests {
    @Test("Identifiers are backtick-quoted with embedded backticks doubled")
    func quoting() {
        #expect(Neo4jCypher.quote("Person") == "`Person`")
        #expect(Neo4jCypher.quote("we`ird") == "`we``ird`")
        #expect(Neo4jCypher.quote(#"a\b"#) == #"`a\b`"#)
        #expect(Neo4jCypher.quote(#"x\u0060 RETURN 1"#) == #"`x\uZZZZ0060 RETURN 1`"#)
        #expect(Neo4jCypher.literal(#"it's \ ok"#) == #"'it\'s \\ ok'"#)
    }

    @Test("A label browse pages, sorts and carries the marker the driver reads back")
    func labelBrowse() throws {
        let query = try Neo4jCypher.browseQuery(
            kind: .node,
            name: "Person",
            sort: [(column: "name", ascending: false), (column: "<id>", ascending: true)],
            limit: 200,
            offset: 400
        )
        #expect(query == """
        // TablePro browse: node
        MATCH (n:`Person`)
        RETURN n
        ORDER BY n.`name` DESC, elementId(n) ASC
        SKIP 400 LIMIT 200
        """)
        #expect(Neo4jCypher.browseKind(of: query) == .node)
        #expect(Neo4jCypher.browseKind(of: "MATCH (n) RETURN n") == nil)
    }

    @Test("A relationship browse matches directed relationships of one type")
    func relationshipBrowse() throws {
        let query = try Neo4jCypher.browseQuery(kind: .relationship, name: "KNOWS", limit: 10, offset: 0, usesElementId: false)
        #expect(query.contains("MATCH ()-[n:`KNOWS`]->()"))
        #expect(Neo4jCypher.browseKind(of: query) == .relationship)
    }

    @Test("Filters become a WHERE clause joined by the logic mode")
    func filters() throws {
        let query = try Neo4jCypher.browseQuery(
            kind: .node,
            name: "Person",
            filters: [
                Neo4jFilter(column: "age", op: ">=", value: "30"),
                Neo4jFilter(column: "name", op: "CONTAINS", value: "an", isCaseSensitive: false)
            ],
            matchesAll: false,
            limit: 10,
            offset: 0
        )
        #expect(query.contains("WHERE (n.`age` >= 30) OR (toLower(toStringOrNull(n.`name`)) CONTAINS 'an')"))
    }

    @Test("Equality on a number also matches the same text stored as a string")
    func untypedEquality() throws {
        let clause = try Neo4jCypher.condition(for: Neo4jFilter(column: "zip", op: "=", value: "123"), usesElementId: true)
        #expect(clause == "(n.`zip` = 123 OR n.`zip` = '123')")
        let text = try Neo4jCypher.condition(for: Neo4jFilter(column: "name", op: "=", value: "Ann"), usesElementId: true)
        #expect(text == "n.`name` = 'Ann'")
        let id = try Neo4jCypher.condition(for: Neo4jFilter(column: "<id>", op: "=", value: "4:x:1"), usesElementId: true)
        #expect(id == "elementId(n) = '4:x:1'")
    }

    @Test("Text filters read any value as text, and labels match when one of them does")
    func textFilters() throws {
        let number = try Neo4jCypher.condition(for: Neo4jFilter(column: "age", op: "CONTAINS", value: "3"), usesElementId: true)
        #expect(number == "toStringOrNull(n.`age`) CONTAINS '3'")
        let labels = try Neo4jCypher.condition(
            for: Neo4jFilter(column: "<labels>", op: "STARTS WITH", value: "Per", isCaseSensitive: false), usesElementId: true
        )
        #expect(labels == "any(label IN labels(n) WHERE toLower(label) STARTS WITH 'per')")
        let legacyId = try Neo4jCypher.condition(for: Neo4jFilter(column: "<id>", op: "ENDS WITH", value: "7"), usesElementId: false)
        #expect(legacyId == "toStringOrNull(id(n)) ENDS WITH '7'")
    }

    @Test("Clearing case sensitivity applies to equality and lists too")
    func caseInsensitiveEquality() throws {
        let equal = try Neo4jCypher.condition(
            for: Neo4jFilter(column: "name", op: "=", value: "Alice", isCaseSensitive: false), usesElementId: true
        )
        #expect(equal == "toLower(toStringOrNull(n.`name`)) IN ['alice']")
        let number = try Neo4jCypher.condition(
            for: Neo4jFilter(column: "age", op: "!=", value: "30", isCaseSensitive: false), usesElementId: true
        )
        #expect(number == "NOT ((n.`age` IN [30] OR toLower(toStringOrNull(n.`age`)) IN ['30']))")
        let list = try Neo4jCypher.condition(
            for: Neo4jFilter(column: "name", op: "NOT IN", value: "Ann, Bo", isCaseSensitive: false), usesElementId: true
        )
        #expect(list == "NOT (toLower(toStringOrNull(n.`name`)) IN ['ann', 'bo'])")
        let mixed = try Neo4jCypher.condition(
            for: Neo4jFilter(column: "zip", op: "IN", value: "1, A", isCaseSensitive: false), usesElementId: true
        )
        #expect(mixed == "(n.`zip` IN [1] OR toLower(toStringOrNull(n.`zip`)) IN ['1', 'a'])")
        let id = try Neo4jCypher.condition(
            for: Neo4jFilter(column: "<id>", op: "=", value: "4:X:1", isCaseSensitive: false), usesElementId: true
        )
        #expect(id == "elementId(n) = '4:X:1'")
    }

    @Test("A list matches each item as typed and as text, like equality does")
    func inList() throws {
        let list = try Neo4jCypher.condition(for: Neo4jFilter(column: "zip", op: "IN", value: "1, a"), usesElementId: true)
        #expect(list == "n.`zip` IN [1, '1', 'a']")
    }

    @Test("Only canonical numbers become number literals")
    func numberLiterals() {
        #expect(Neo4jCypher.typedLiteral("42") == "42")
        #expect(Neo4jCypher.typedLiteral("-7") == "-7")
        #expect(Neo4jCypher.typedLiteral("2.5") == "2.5")
        #expect(Neo4jCypher.typedLiteral("01234") == "'01234'")
        #expect(Neo4jCypher.typedLiteral("08") == "'08'")
        #expect(Neo4jCypher.typedLiteral("99999999999999999999") == "'99999999999999999999'")
        #expect(Neo4jCypher.typedLiteral("5.") == "'5.'")
        #expect(Neo4jCypher.typedLiteral("+3") == "'+3'")
        #expect(Neo4jCypher.typedLiteral("TRUE") == "true")
    }

    @Test("A filtered count uses the same conditions as the page it counts")
    func filteredCount() throws {
        let query = try Neo4jCypher.countQuery(
            kind: .relationship,
            name: "KNOWS",
            filters: [Neo4jFilter(column: "since", op: ">", value: "2020")],
            usesElementId: true
        )
        #expect(query == "MATCH ()-[n:`KNOWS`]->()\nWHERE n.`since` > 2020\nRETURN count(n) AS count")
        #expect(try Neo4jCypher.countQuery(kind: .node, name: "A") == "MATCH (n:`A`)\nRETURN count(n) AS count")
    }

    @Test("A name holding a unicode escape is refused, since Neo4j would decode it inside the quotes")
    func unicodeEscapeNames() {
        let name = #"x\u0060 IS NULL DETACH DELETE n"#
        #expect(throws: Neo4jCypherError.unquotableName(name)) {
            try Neo4jCypher.browseQuery(kind: .node, name: name, limit: 1, offset: 0)
        }
        #expect(throws: Neo4jCypherError.unquotableName(name)) {
            try Neo4jCypher.countQuery(kind: .node, name: "A", filters: [Neo4jFilter(column: name, op: "IS NULL", value: "")])
        }
        #expect(throws: Neo4jCypherError.unquotableName(name)) {
            try Neo4jCypher.browseQuery(kind: .node, name: "A", sort: [(name, true)], limit: 1, offset: 0)
        }
    }

    @Test("An unknown operator is refused")
    func unknownOperator() {
        #expect(throws: Neo4jCypherError.unsupportedOperator("~~")) {
            try Neo4jCypher.condition(for: Neo4jFilter(column: "a", op: "~~", value: "x"), usesElementId: true)
        }
    }

    @Test("Schema names map back to entity kinds")
    func kinds() {
        #expect(Neo4jEntityKind(schemaName: "Labels") == .node)
        #expect(Neo4jEntityKind(schemaName: "Relationship Types") == .relationship)
        #expect(Neo4jEntityKind(schemaName: "public") == nil)
    }
}
