//
//  DynamoDBFilterTranslatorTests.swift
//  TableProTests
//

import Foundation
import Testing

struct DynamoDBFilterTranslatorTests {
    struct Translation {
        let outcome: DynamoDBFilterTranslator.Outcome
        let context: DynamoDBExpressionContext
    }

    struct OperatorCase: Sendable, CustomTestStringConvertible {
        let op: String
        let value: String

        var testDescription: String { "\(op) \(value)" }
    }

    static func schema() throws -> DynamoDBTableSchema {
        let json = try DynamoDBJSON.parse("""
            {"Table": {
                "TableName": "orders",
                "KeySchema": [
                    {"AttributeName": "pk", "KeyType": "HASH"},
                    {"AttributeName": "sk", "KeyType": "RANGE"}
                ],
                "AttributeDefinitions": [
                    {"AttributeName": "pk", "AttributeType": "S"},
                    {"AttributeName": "sk", "AttributeType": "N"}
                ]
            }}
            """)
        return try DynamoDBTableSchema(describeTableResponse: json)
    }

    static func filter(
        _ attribute: String,
        _ op: String,
        _ value: String = "",
        second: String? = nil,
        kind: String? = nil,
        caseSensitive: Bool = true
    ) -> DynamoDBBrowseFilter {
        DynamoDBBrowseFilter(
            attribute: attribute, op: op, value: value, secondValue: second, kind: kind, caseSensitive: caseSensitive
        )
    }

    static func translate(_ filter: DynamoDBBrowseFilter) throws -> Translation {
        let translator = DynamoDBFilterTranslator(schema: try schema())
        var context = DynamoDBExpressionContext()
        let path: DynamoDBAttributePath? = filter.attribute == DynamoDBFilterTranslator.anyAttributeColumn
            ? nil
            : DynamoDBAttributePath.parse(filter.attribute, knownAttributes: [])
        let outcome = translator.translate(filter, path: path, context: &context)
        return Translation(outcome: outcome, context: context)
    }

    static func keyCondition(_ filter: DynamoDBBrowseFilter) throws -> (term: String?, context: DynamoDBExpressionContext) {
        let translator = DynamoDBFilterTranslator(schema: try schema())
        var context = DynamoDBExpressionContext()
        let term = translator.keyCondition(filter, attribute: filter.attribute, context: &context)
        return (term, context)
    }

    static func clientPredicate(_ filter: DynamoDBBrowseFilter, path: String?) -> DynamoDBClientPredicate {
        DynamoDBClientPredicate(
            path: path.map { DynamoDBAttributePath(attribute: $0) },
            op: filter.op,
            value: filter.value,
            secondValue: filter.secondValue,
            caseSensitive: filter.caseSensitive
        )
    }

    // MARK: - Equality and ordering

    @Test("Numeric text on a non-key attribute is compared as both a String and a Number")
    func equalityOnNumericText() throws {
        let result = try Self.translate(Self.filter("total", "=", "5"))

        #expect(result.outcome == .server("(#total = :total OR #total = :total2)"))
        #expect(result.context.names == ["#total": "total"])
        #expect(result.context.values == [":total": .string("5"), ":total2": .number("5")])
    }

    @Test("Equality with true also matches a Boolean")
    func equalityOnTrue() throws {
        let result = try Self.translate(Self.filter("flag", "=", "true"))

        #expect(result.outcome == .server("(#flag = :flag OR #flag = :flag2)"))
        #expect(result.context.values == [":flag": .string("true"), ":flag2": .bool(true)])
    }

    @Test("Plain text is compared as a String only")
    func equalityOnText() throws {
        let result = try Self.translate(Self.filter("name", "=", "Ann"))

        #expect(result.outcome == .server("#name = :name"))
        #expect(result.context.values == [":name": .string("Ann")])
    }

    @Test("An ordering comparison on numeric text uses a String and a Number", arguments: [">", ">=", "<", "<="])
    func orderingOnNumericText(op: String) throws {
        let result = try Self.translate(Self.filter("total", op, "5"))

        #expect(result.outcome == .server("(#total \(op) :total OR #total \(op) :total2)"))
        #expect(result.context.values == [":total": .string("5"), ":total2": .number("5")])
    }

    @Test("An ordering comparison never compares a Boolean", arguments: [">", ">=", "<", "<="])
    func orderingNeverUsesBoolean(op: String) throws {
        let result = try Self.translate(Self.filter("flag", op, "true"))

        #expect(result.outcome == .server("#flag \(op) :flag"))
        #expect(result.context.values == [":flag": .string("true")])
    }

    @Test("Not equal requires the attribute and excludes every reading of the text", arguments: ["!=", "<>"])
    func notEqual(op: String) throws {
        let result = try Self.translate(Self.filter("total", op, "5"))

        #expect(result.outcome == .server("(attribute_exists(#total) AND #total <> :total AND #total <> :total2)"))
        #expect(result.context.values == [":total": .string("5"), ":total2": .number("5")])
    }

    @Test("Not equal to true excludes the text and the Boolean")
    func notEqualToTrue() throws {
        let result = try Self.translate(Self.filter("flag", "!=", "true"))

        #expect(result.outcome == .server("(attribute_exists(#flag) AND #flag <> :flag AND #flag <> :flag2)"))
        #expect(result.context.values == [":flag": .string("true"), ":flag2": .bool(true)])
    }

    // MARK: - Text operators

    @Test("Contains becomes the contains function")
    func contains() throws {
        let text = try Self.translate(Self.filter("name", "CONTAINS", "ab"))
        let numeric = try Self.translate(Self.filter("total", "CONTAINS", "5"))

        #expect(text.outcome == .server("contains(#name, :name)"))
        #expect(text.context.values == [":name": .string("ab")])
        #expect(numeric.outcome == .server("(contains(#total, :total) OR contains(#total, :total2))"))
        #expect(numeric.context.values == [":total": .string("5"), ":total2": .number("5")])
    }

    @Test("Not contains requires the attribute")
    func notContains() throws {
        let result = try Self.translate(Self.filter("name", "NOT CONTAINS", "ab"))

        #expect(result.outcome == .server("(attribute_exists(#name) AND NOT contains(#name, :name))"))
        #expect(result.context.values == [":name": .string("ab")])
    }

    @Test("Starts with becomes begins_with on a String")
    func startsWith() throws {
        let text = try Self.translate(Self.filter("name", "STARTS WITH", "ab"))
        let digits = try Self.translate(Self.filter("name", "STARTS WITH", "12"))

        #expect(text.outcome == .server("begins_with(#name, :name)"))
        #expect(text.context.values == [":name": .string("ab")])
        #expect(digits.outcome == .server("begins_with(#name, :name)"))
        #expect(digits.context.values == [":name": .string("12")])
    }

    @Test("Ends with and a regular expression are evaluated on the client", arguments: ["ENDS WITH", "REGEX"])
    func clientOnlyOperators(op: String) throws {
        let filter = Self.filter("name", op, "son")

        let result = try Self.translate(filter)

        #expect(result.outcome == .client(Self.clientPredicate(filter, path: "name")))
        #expect(result.context == DynamoDBExpressionContext())
    }

    // MARK: - Null and empty

    @Test("Is null matches a missing attribute or the NULL type")
    func isNull() throws {
        let result = try Self.translate(Self.filter("total", "IS NULL"))

        #expect(result.outcome == .server("(attribute_not_exists(#total) OR attribute_type(#total, :null))"))
        #expect(result.context.values == [":null": .string("NULL")])
    }

    @Test("Is not null requires the attribute and rejects the NULL type")
    func isNotNull() throws {
        let result = try Self.translate(Self.filter("total", "IS NOT NULL"))

        #expect(result.outcome == .server("(attribute_exists(#total) AND NOT attribute_type(#total, :null))"))
        #expect(result.context.values == [":null": .string("NULL")])
    }

    @Test("Is empty compares with the empty String")
    func isEmpty() throws {
        let result = try Self.translate(Self.filter("name", "IS EMPTY"))

        #expect(result.outcome == .server("#name = :empty"))
        #expect(result.context.values == [":empty": .string("")])
    }

    @Test("Is not empty requires the attribute and a value other than the empty String")
    func isNotEmpty() throws {
        let result = try Self.translate(Self.filter("name", "IS NOT EMPTY"))

        #expect(result.outcome == .server("(attribute_exists(#name) AND #name <> :empty)"))
        #expect(result.context.values == [":empty": .string("")])
    }

    // MARK: - Membership

    @Test("In lists every typed reading of each value")
    func inList() throws {
        let text = try Self.translate(Self.filter("name", "IN", "a, b"))
        let numeric = try Self.translate(Self.filter("total", "IN", "1, 2"))

        #expect(text.outcome == .server("#name IN (:name, :name2)"))
        #expect(text.context.values == [":name": .string("a"), ":name2": .string("b")])
        #expect(numeric.outcome == .server("#total IN (:total, :total2, :total3, :total4)"))
        #expect(numeric.context.values == [
            ":total": .string("1"), ":total2": .number("1"), ":total3": .string("2"), ":total4": .number("2")
        ])
    }

    @Test("Not in requires the attribute")
    func notInList() throws {
        let result = try Self.translate(Self.filter("name", "NOT IN", "a, b"))

        #expect(result.outcome == .server("(attribute_exists(#name) AND NOT #name IN (:name, :name2))"))
    }

    @Test("In with 150 values is split into IN terms of at most 100")
    func inListChunks() throws {
        let values = (0..<150).map { "v\($0)" }.joined(separator: ", ")

        let result = try Self.translate(Self.filter("name", "IN", values))

        guard case .server(let expression) = result.outcome else {
            Issue.record("Expected a server expression, got \(result.outcome)")
            return
        }
        let regex = try NSRegularExpression(pattern: #"IN \(([^)]*)\)"#)
        let range = NSRange(expression.startIndex..., in: expression)
        let chunkSizes = regex.matches(in: expression, range: range).compactMap { match -> Int? in
            Range(match.range(at: 1), in: expression).map { expression[$0].components(separatedBy: ", ").count }
        }
        #expect(chunkSizes == [100, 50])
        #expect(expression.hasPrefix("(#name IN ("))
        #expect(expression.contains(") OR #name IN ("))
        #expect(result.context.values.count == 150)
    }

    // MARK: - Between

    @Test("Between with a second value compares as a String range and a Number range")
    func betweenWithSecondValue() throws {
        let result = try Self.translate(Self.filter("total", "BETWEEN", "1", second: "9"))

        #expect(result.outcome == .server(
            "(#total BETWEEN :total AND :total2 OR #total BETWEEN :total3 AND :total4)"
        ))
        #expect(result.context.values == [
            ":total": .string("1"), ":total2": .string("9"), ":total3": .number("1"), ":total4": .number("9")
        ])
    }

    @Test("Between reads both bounds from one comma separated value", arguments: [
        OperatorCase(op: "BETWEEN", value: "1,9"),
        OperatorCase(op: "BETWEEN", value: " 1 , 9 ")
    ])
    func betweenFromOneValue(_ testCase: OperatorCase) throws {
        let result = try Self.translate(Self.filter("total", testCase.op, testCase.value))

        #expect(result.outcome == .server(
            "(#total BETWEEN :total AND :total2 OR #total BETWEEN :total3 AND :total4)"
        ))
        #expect(result.context.values[":total3"] == .number("1"))
        #expect(result.context.values[":total4"] == .number("9"))
    }

    @Test("Between drops the String range when its bounds are out of order as text")
    func betweenDropsReversedTextRange() throws {
        let result = try Self.translate(Self.filter("total", "BETWEEN", "2", second: "10"))

        #expect(result.outcome == .server("#total BETWEEN :total AND :total2"))
        #expect(result.context.values == [":total": .number("2"), ":total2": .number("10")])
    }

    @Test("Between never compares Booleans")
    func betweenNeverUsesBoolean() throws {
        let result = try Self.translate(Self.filter("flag", "BETWEEN", "false", second: "true"))

        #expect(result.outcome == .server("#flag BETWEEN :flag AND :flag2"))
        #expect(result.context.values == [":flag": .string("false"), ":flag2": .string("true")])
    }

    // MARK: - Key attributes

    @Test("A Number key compares as a Number only")
    func numberKeyIsTypedNumber() throws {
        let equal = try Self.translate(Self.filter("sk", "=", "5"))
        let greater = try Self.translate(Self.filter("sk", ">", "5"))

        #expect(equal.outcome == .server("#sk = :sk"))
        #expect(equal.context.values == [":sk": .number("5")])
        #expect(greater.outcome == .server("#sk > :sk"))
        #expect(greater.context.values == [":sk": .number("5")])
    }

    @Test("A String key compares numeric text as a String only")
    func stringKeyIsTypedString() throws {
        let result = try Self.translate(Self.filter("pk", "=", "5"))

        #expect(result.outcome == .server("#pk = :pk"))
        #expect(result.context.values == [":pk": .string("5")])
    }

    @Test("A Number key compared with text that is not a number matches nothing", arguments: [
        OperatorCase(op: "=", value: "abc"),
        OperatorCase(op: ">", value: "abc"),
        OperatorCase(op: ">=", value: "abc"),
        OperatorCase(op: "<", value: "abc"),
        OperatorCase(op: "<=", value: "abc"),
        OperatorCase(op: "IN", value: "abc, def"),
        OperatorCase(op: "BETWEEN", value: "a,b"),
        OperatorCase(op: "BETWEEN", value: "9,1")
    ])
    func numberKeyWithTextMatchesNothing(_ testCase: OperatorCase) throws {
        let result = try Self.translate(Self.filter("sk", testCase.op, testCase.value))

        #expect(result.outcome == .never)
    }

    @Test("Starts with on a Number key matches nothing")
    func startsWithOnNumberKey() throws {
        let result = try Self.translate(Self.filter("sk", "STARTS WITH", "1"))

        #expect(result.outcome == .never)
    }

    @Test("In on a Number key keeps only the values that are numbers")
    func numberKeyInKeepsNumbers() throws {
        let result = try Self.translate(Self.filter("sk", "IN", "1, abc, 2"))

        #expect(result.outcome == .server("#sk IN (:sk, :sk2)"))
        #expect(result.context.values == [":sk": .number("1"), ":sk2": .number("2")])
    }

    @Test("Not equal or not in on a Number key with text keeps every item that has the key", arguments: [
        OperatorCase(op: "!=", value: "abc"),
        OperatorCase(op: "NOT IN", value: "abc")
    ])
    func numberKeyExclusionWithText(_ testCase: OperatorCase) throws {
        let result = try Self.translate(Self.filter("sk", testCase.op, testCase.value))

        #expect(result.outcome == .server("attribute_exists(#sk)"))
        #expect(result.context.values.isEmpty)
    }

    // MARK: - Client side filters

    @Test("A search across every attribute is evaluated on the client")
    func anyAttributeColumn() throws {
        let filter = Self.filter("*", "=", "x")

        let result = try Self.translate(filter)

        #expect(result.outcome == .client(Self.clientPredicate(filter, path: nil)))
        #expect(DynamoDBFilterTranslator(schema: try Self.schema()).needsClient(filter))
    }

    @Test(
        "A case-insensitive match on text with letters is evaluated on the client",
        arguments: ["=", "!=", "<>", "CONTAINS", "NOT CONTAINS", "STARTS WITH", "IN", "NOT IN"]
    )
    func caseInsensitiveNeedsClient(op: String) throws {
        let filter = Self.filter("name", op, "Ab", caseSensitive: false)

        let result = try Self.translate(filter)

        #expect(result.outcome == .client(Self.clientPredicate(filter, path: "name")))
        #expect(result.context == DynamoDBExpressionContext())
    }

    @Test("A case-insensitive match on text without letters stays on the server")
    func caseInsensitiveWithoutLetters() throws {
        let result = try Self.translate(Self.filter("name", "CONTAINS", "12", caseSensitive: false))

        #expect(result.outcome == .server("(contains(#name, :name) OR contains(#name, :name2))"))
    }

    @Test("Only the raw filter column is refused")
    func unsupportedReason() {
        let raw = DynamoDBFilterTranslator.unsupportedReason(for: Self.filter("__RAW__", "=", "a = 1"))

        #expect(raw?.isEmpty == false)
        #expect(DynamoDBFilterTranslator.unsupportedReason(for: Self.filter("name", "=", "a")) == nil)
        #expect(DynamoDBFilterTranslator.unsupportedReason(for: Self.filter("*", "=", "a")) == nil)
    }

    // MARK: - Key conditions

    @Test("Equality on a String key is a key condition")
    func keyConditionEquality() throws {
        let result = try Self.keyCondition(Self.filter("pk", "=", "a"))

        #expect(result.term == "#pk = :pk")
        #expect(result.context.names == ["#pk": "pk"])
        #expect(result.context.values == [":pk": .string("a")])
    }

    @Test("A range on a Number key is a key condition typed as a Number")
    func keyConditionRange() throws {
        let result = try Self.keyCondition(Self.filter("sk", "<", "5"))

        #expect(result.term == "#sk < :sk")
        #expect(result.context.values == [":sk": .number("5")])
    }

    @Test("Between on a Number key is a key condition", arguments: [
        OperatorCase(op: "BETWEEN", value: "1,9"),
        OperatorCase(op: "BETWEEN", value: "1 , 9")
    ])
    func keyConditionBetween(_ testCase: OperatorCase) throws {
        let result = try Self.keyCondition(Self.filter("sk", testCase.op, testCase.value))

        #expect(result.term == "#sk BETWEEN :sk AND :sk2")
        #expect(result.context.values == [":sk": .number("1"), ":sk2": .number("9")])
    }

    @Test("Between with a second value is a key condition")
    func keyConditionBetweenWithSecondValue() throws {
        let result = try Self.keyCondition(Self.filter("sk", "BETWEEN", "1", second: "9"))

        #expect(result.term == "#sk BETWEEN :sk AND :sk2")
        #expect(result.context.values == [":sk": .number("1"), ":sk2": .number("9")])
    }

    @Test("Starts with on a String key is a begins_with key condition")
    func keyConditionStartsWith() throws {
        let result = try Self.keyCondition(Self.filter("pk", "STARTS WITH", "ab"))

        #expect(result.term == "begins_with(#pk, :pk)")
        #expect(result.context.values == [":pk": .string("ab")])
    }

    @Test("Filters a key condition cannot express are refused", arguments: [
        DynamoDBFilterTranslatorTests.filter("sk", "STARTS WITH", "1"),
        DynamoDBFilterTranslatorTests.filter("sk", "=", "abc"),
        DynamoDBFilterTranslatorTests.filter("sk", "BETWEEN", "a,b"),
        DynamoDBFilterTranslatorTests.filter("pk", "!=", "a"),
        DynamoDBFilterTranslatorTests.filter("pk", "CONTAINS", "a"),
        DynamoDBFilterTranslatorTests.filter("pk", "IN", "a, b"),
        DynamoDBFilterTranslatorTests.filter("pk", "ENDS WITH", "a"),
        DynamoDBFilterTranslatorTests.filter("pk", "=", "Ab", caseSensitive: false),
        DynamoDBFilterTranslatorTests.filter("name", "=", "a")
    ])
    func keyConditionRefusals(_ filter: DynamoDBBrowseFilter) throws {
        let result = try Self.keyCondition(filter)

        #expect(result.term == nil)
    }
}

struct DynamoDBClientPredicateMatchingTests {
    static func predicate(
        _ op: String,
        _ value: String = "",
        second: String? = nil,
        path: String? = "name",
        caseSensitive: Bool = true
    ) -> DynamoDBClientPredicate {
        DynamoDBClientPredicate(
            path: path.map { DynamoDBAttributePath.parse($0, knownAttributes: []) },
            op: op,
            value: value,
            secondValue: second,
            caseSensitive: caseSensitive
        )
    }

    static let alice: DynamoDBItem = ["name": .string("Alice"), "city": .string("Hanoi")]

    @Test("Equality compares the displayed text, folding case only when asked")
    func equality() {
        #expect(Self.predicate("=", "Alice").matches(Self.alice))
        #expect(!Self.predicate("=", "alice").matches(Self.alice))
        #expect(Self.predicate("=", "alice", caseSensitive: false).matches(Self.alice))
        #expect(Self.predicate("=", "true").matches(["name": .bool(true)]))
    }

    @Test("A Number equals the same number written another way")
    func numericEquality() {
        #expect(Self.predicate("=", "5.0").matches(["name": .number("5")]))
        #expect(!Self.predicate("!=", "5.0").matches(["name": .number("5")]))
    }

    @Test("Not equal is the inverse of equality for an attribute that exists", arguments: ["!=", "<>"])
    func notEqual(op: String) {
        #expect(Self.predicate(op, "Bob").matches(Self.alice))
        #expect(!Self.predicate(op, "Alice").matches(Self.alice))
        #expect(!Self.predicate(op, "ALICE", caseSensitive: false).matches(Self.alice))
    }

    @Test("Contains and not contains test a substring")
    func contains() {
        #expect(Self.predicate("CONTAINS", "lic").matches(Self.alice))
        #expect(!Self.predicate("CONTAINS", "LIC").matches(Self.alice))
        #expect(Self.predicate("CONTAINS", "LIC", caseSensitive: false).matches(Self.alice))
        #expect(Self.predicate("NOT CONTAINS", "xyz").matches(Self.alice))
        #expect(!Self.predicate("NOT CONTAINS", "lic").matches(Self.alice))
    }

    @Test("Starts with and ends with test a prefix and a suffix")
    func prefixAndSuffix() {
        #expect(Self.predicate("STARTS WITH", "Al").matches(Self.alice))
        #expect(!Self.predicate("STARTS WITH", "li").matches(Self.alice))
        #expect(Self.predicate("STARTS WITH", "al", caseSensitive: false).matches(Self.alice))
        #expect(Self.predicate("ENDS WITH", "ice").matches(Self.alice))
        #expect(!Self.predicate("ENDS WITH", "Ali").matches(Self.alice))
        #expect(Self.predicate("ENDS WITH", "ICE", caseSensitive: false).matches(Self.alice))
    }

    @Test("Is empty and is not empty need the attribute")
    func emptiness() {
        #expect(Self.predicate("IS EMPTY").matches(["name": .string("")]))
        #expect(!Self.predicate("IS EMPTY").matches(Self.alice))
        #expect(!Self.predicate("IS EMPTY").matches([:]))
        #expect(Self.predicate("IS NOT EMPTY").matches(Self.alice))
        #expect(!Self.predicate("IS NOT EMPTY").matches(["name": .string("")]))
        #expect(!Self.predicate("IS NOT EMPTY").matches([:]))
    }

    @Test("Is null matches a missing attribute and the NULL type, not the text NULL")
    func nullness() {
        #expect(Self.predicate("IS NULL").matches([:]))
        #expect(Self.predicate("IS NULL").matches(["name": .null]))
        #expect(!Self.predicate("IS NULL").matches(["name": .string("NULL")]))
        #expect(!Self.predicate("IS NULL").matches(Self.alice))
        #expect(Self.predicate("IS NOT NULL").matches(Self.alice))
        #expect(!Self.predicate("IS NOT NULL").matches(["name": .null]))
        #expect(!Self.predicate("IS NOT NULL").matches([:]))
    }

    @Test("In and not in test membership of a comma separated list")
    func membership() {
        #expect(Self.predicate("IN", "Bob, Alice").matches(Self.alice))
        #expect(!Self.predicate("IN", "Bob, Carol").matches(Self.alice))
        #expect(Self.predicate("IN", "bob, alice", caseSensitive: false).matches(Self.alice))
        #expect(Self.predicate("NOT IN", "Bob, Carol").matches(Self.alice))
        #expect(!Self.predicate("NOT IN", "Alice").matches(Self.alice))
    }

    @Test("A regular expression is searched in the text, folding case only when asked")
    func regularExpression() {
        #expect(Self.predicate("REGEX", "^A.*e$").matches(Self.alice))
        #expect(Self.predicate("REGEX", "lic").matches(Self.alice))
        #expect(!Self.predicate("REGEX", "^a").matches(Self.alice))
        #expect(Self.predicate("REGEX", "^a", caseSensitive: false).matches(Self.alice))
        #expect(!Self.predicate("REGEX", "(").matches(Self.alice))
    }

    @Test("Numbers are ordered by value, not as text")
    func numericOrdering() {
        let ten: DynamoDBItem = ["name": .number("10")]

        #expect(Self.predicate(">", "9").matches(ten))
        #expect(!Self.predicate("<", "9").matches(ten))
        #expect(Self.predicate(">=", "10.0").matches(ten))
        #expect(Self.predicate("<=", "1E1").matches(ten))
        #expect(!Self.predicate(">", "10").matches(ten))
    }

    @Test("Text is ordered as text")
    func textOrdering() {
        let banana: DynamoDBItem = ["name": .string("banana")]

        #expect(Self.predicate(">", "apple").matches(banana))
        #expect(Self.predicate("<", "cherry").matches(banana))
        #expect(!Self.predicate("<", "apple").matches(banana))
    }

    @Test("Between is inclusive and numeric when both bounds are numbers")
    func between() {
        #expect(Self.predicate("BETWEEN", "2", second: "10").matches(["name": .number("5")]))
        #expect(Self.predicate("BETWEEN", "2,10").matches(["name": .number("5")]))
        #expect(Self.predicate("BETWEEN", "2", second: "10").matches(["name": .number("2")]))
        #expect(Self.predicate("BETWEEN", "2", second: "10").matches(["name": .number("10")]))
        #expect(!Self.predicate("BETWEEN", "2", second: "10").matches(["name": .number("11")]))
        #expect(Self.predicate("BETWEEN", "a", second: "c").matches(["name": .string("b")]))
        #expect(!Self.predicate("BETWEEN", "5").matches(["name": .number("5")]))
    }

    @Test("CONTAINS and STARTS WITH on the client answer as DynamoDB's contains and begins_with would")
    func clientMatchingFollowsDynamoDB() {
        let list: DynamoDBItem = ["tags": .list([.string("Abc"), .number("5")])]
        let number: DynamoDBItem = ["tags": .number("123")]
        let numbers: DynamoDBItem = ["tags": .numberSet(["5", "7"])]
        let path = DynamoDBAttributePath(attribute: "tags")

        func matches(_ op: String, _ value: String, _ item: DynamoDBItem) -> Bool {
            DynamoDBClientPredicate(path: path, op: op, value: value, secondValue: nil, caseSensitive: false).matches(item)
        }

        #expect(matches("CONTAINS", "abc", list))
        #expect(!matches("CONTAINS", "ab", list))
        #expect(matches("CONTAINS", "5.0", list))
        #expect(!matches("CONTAINS", "12", number))
        #expect(matches("NOT CONTAINS", "12", number))
        #expect(matches("CONTAINS", "5.0", numbers))
        #expect(!matches("STARTS WITH", "12", number))
    }

    @Test("A missing attribute matches no comparison", arguments: [
        "=", "!=", "<>", ">", "<", "CONTAINS", "NOT CONTAINS", "STARTS WITH", "ENDS WITH", "IN", "NOT IN", "REGEX"
    ])
    func missingAttribute(op: String) {
        #expect(!Self.predicate(op, "x").matches(["other": .string("x")]))
    }

    @Test("A search across every attribute matches when any attribute does")
    func anyAttribute() {
        #expect(Self.predicate("=", "Hanoi", path: nil).matches(Self.alice))
        #expect(!Self.predicate("=", "Paris", path: nil).matches(Self.alice))
        #expect(Self.predicate("CONTAINS", "NOI", path: nil, caseSensitive: false).matches(Self.alice))
        #expect(Self.predicate("REGEX", "^Han", path: nil).matches(Self.alice))
    }

    @Test("A nested path reads the value inside a map")
    func nestedPath() {
        let item: DynamoDBItem = ["address": .map(["city": .string("Hanoi")])]

        #expect(Self.predicate("=", "Hanoi", path: "address.city").matches(item))
        #expect(!Self.predicate("=", "Hanoi", path: "address.zip").matches(item))
    }
}
