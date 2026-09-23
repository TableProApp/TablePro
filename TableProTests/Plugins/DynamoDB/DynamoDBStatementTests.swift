import Foundation
import TableProPluginKit
import Testing

@Suite("DynamoDB statement parsing")
struct DynamoDBStatementTests {
    struct WindowCase: Sendable, CustomTestStringConvertible {
        let clause: String
        let window: DynamoDBReadWindow

        var testDescription: String { clause }
    }

    static let ordersBody: DynamoDBJSON = .object(["TableName": .string("Orders")])

    static let windowCases: [WindowCase] = [
        WindowCase(
            clause: "ORDER BY \"a\"\"b\" DESC",
            window: DynamoDBReadWindow(order: [DynamoDBOrderTerm(attribute: "a\"b", descending: true)])
        ),
        WindowCase(
            clause: "ORDER BY \"a\" DESC, b, \"c\" ASC",
            window: DynamoDBReadWindow(order: [
                DynamoDBOrderTerm(attribute: "a", descending: true),
                DynamoDBOrderTerm(attribute: "b", descending: false),
                DynamoDBOrderTerm(attribute: "c", descending: false)
            ])
        ),
        WindowCase(clause: "LIMIT 25", window: DynamoDBReadWindow(limit: 25)),
        WindowCase(clause: "LIMIT 0", window: DynamoDBReadWindow(limit: 0)),
        WindowCase(clause: "OFFSET 40", window: DynamoDBReadWindow(offset: 40)),
        WindowCase(clause: "LIMIT 25 OFFSET 50", window: DynamoDBReadWindow(limit: 25, offset: 50)),
        WindowCase(
            clause: "order by \"sk\" desc limit 5 offset 10",
            window: DynamoDBReadWindow(
                order: [DynamoDBOrderTerm(attribute: "sk", descending: true)],
                limit: 5,
                offset: 10
            )
        ),
        WindowCase(
            clause: "ORDER BY \"sk\" ASC LIMIT 5 -- first page",
            window: DynamoDBReadWindow(order: [DynamoDBOrderTerm(attribute: "sk", descending: false)], limit: 5)
        )
    ]

    static let malformedWindows: [String] = [
        "WHERE \"a\" = 1",
        "ORDER BY",
        "ORDER \"a\"",
        "ORDER BY 1",
        "ORDER BY \"a\",",
        "ORDER BY \"a\" DESC DESC",
        "LIMIT",
        "LIMIT ten",
        "LIMIT -1",
        "LIMIT 1.5",
        "OFFSET -2",
        "LIMIT 5 ORDER BY \"a\"",
        "OFFSET 2 LIMIT 5",
        "LIMIT 5 LIMIT 6",
        "; Scan {\"TableName\":\"Orders\"}"
    ]

    static let roundTripStatements: [DynamoDBStatement] = [
        .partiQL(text: "SELECT * FROM \"Orders\"", window: DynamoDBReadWindow()),
        .partiQL(
            text: "SELECT * FROM \"Orders\" WHERE \"pk\" = 'a'",
            window: DynamoDBReadWindow(
                order: [
                    DynamoDBOrderTerm(attribute: "sk", descending: true),
                    DynamoDBOrderTerm(attribute: "a\"b", descending: false)
                ],
                limit: 5,
                offset: 10
            )
        ),
        .partiQL(text: "UPDATE \"Orders\" SET \"a\" = 1 WHERE \"pk\" = 'a'", window: DynamoDBReadWindow()),
        .apiCall(DynamoDBAPICall(operation: .scan, body: ordersBody), window: DynamoDBReadWindow()),
        .apiCall(
            DynamoDBAPICall(
                operation: .query,
                body: .object([
                    "TableName": .string("Orders"),
                    "Limit": .number("12345678901234567890123456789012345678"),
                    "ConsistentRead": .bool(true),
                    "ExpressionAttributeValues": .object([":p": .object(["S": .string("a/b \"c\"")])])
                ])
            ),
            window: DynamoDBReadWindow(
                order: [DynamoDBOrderTerm(attribute: "a\"b", descending: true)],
                limit: 5,
                offset: 10
            )
        ),
        .apiCall(
            DynamoDBAPICall(operation: .putItem, body: .object([
                "TableName": .string("Orders"),
                "Item": .object(["pk": .object(["S": .string("a")])])
            ])),
            window: DynamoDBReadWindow()
        ),
        .browse(
            DynamoDBBrowseRequest(table: "Orders", filters: [], matchAll: true, columns: []),
            window: DynamoDBReadWindow()
        ),
        .browse(
            DynamoDBBrowseRequest(
                table: "Orders",
                filters: [
                    DynamoDBBrowseFilter(
                        attribute: "status", op: "=", value: "open",
                        secondValue: nil, kind: "text", caseSensitive: false
                    )
                ],
                matchAll: false,
                columns: ["pk", "status"]
            ),
            window: DynamoDBReadWindow(order: [DynamoDBOrderTerm(attribute: "pk", descending: false)], limit: 300)
        )
    ]

    private func failureMessage(_ text: String) -> String? {
        do {
            _ = try DynamoDBStatement.parse(text)
            return nil
        } catch DynamoDBError.invalidStatement(let message) {
            return message
        } catch {
            return nil
        }
    }

    // MARK: - API calls

    @Test("An action verb is matched without regard to case", arguments: ["Scan", "scan", "SCAN", "sCaN"])
    func verbIsCaseInsensitive(verb: String) throws {
        let statement = try DynamoDBStatement.parse("\(verb) {\"TableName\": \"Orders\"}")
        #expect(statement == .apiCall(
            DynamoDBAPICall(operation: .scan, body: Self.ordersBody),
            window: DynamoDBReadWindow()
        ))
    }

    @Test("Every action the editor runs parses under its own name", arguments: DynamoDBOperation.allCases)
    func everyOperationParses(operation: DynamoDBOperation) throws {
        let statement = try DynamoDBStatement.parse("\(operation.rawValue) {}")
        #expect(statement == .apiCall(
            DynamoDBAPICall(operation: operation, body: .object([:])),
            window: DynamoDBReadWindow()
        ))
    }

    @Test("Trailing semicolons and whitespace are stripped")
    func trailingSemicolonsAreStripped() throws {
        let call = try DynamoDBStatement.parse("  Scan {\"TableName\":\"Orders\"} ;; \n")
        #expect(call == .apiCall(DynamoDBAPICall(operation: .scan, body: Self.ordersBody), window: DynamoDBReadWindow()))

        let partiQL = try DynamoDBStatement.parse("SELECT * FROM \"Orders\";\n")
        #expect(partiQL == .partiQL(text: "SELECT * FROM \"Orders\"", window: DynamoDBReadWindow()))
    }

    @Test("The body may follow the verb directly or after a line break")
    func whitespaceBeforeTheBodyIsOptional() throws {
        let expected = DynamoDBStatement.apiCall(
            DynamoDBAPICall(operation: .getItem, body: Self.ordersBody),
            window: DynamoDBReadWindow()
        )
        #expect(try DynamoDBStatement.parse("GetItem{\"TableName\":\"Orders\"}") == expected)
        #expect(try DynamoDBStatement.parse("GetItem\n  {\"TableName\":\"Orders\"}") == expected)
    }

    @Test("A request that is not valid JSON names the action and where the JSON broke")
    func invalidJSONIsReported() throws {
        let message = try #require(failureMessage("Scan {\"TableName\": }"))
        #expect(message.contains("Scan"))
        #expect(message.contains(DynamoDBJSON.ParseError.unexpected(offset: 14).localizedDescription))
    }

    @Test("A request with a duplicate key is reported as invalid JSON")
    func duplicateKeyIsReported() throws {
        let message = try #require(failureMessage("PutItem {\"TableName\": \"a\", \"TableName\": \"b\"}"))
        #expect(message.contains("PutItem"))
        #expect(message.contains(DynamoDBJSON.ParseError.duplicateKey("TableName").localizedDescription))
    }

    @Test("An unterminated request is refused")
    func unterminatedRequestIsRefused() {
        #expect(failureMessage("Query {\"TableName\": \"Orders\"") != nil)
    }

    @Test(
        "An action this editor does not run is refused when a JSON body follows it",
        arguments: ["Frobnicate {\"TableName\": \"Orders\"}", "ListBackups {}", "Scna {\"TableName\": \"Orders\"}"]
    )
    func unknownActionWithBodyIsRefused(text: String) throws {
        let message = try #require(failureMessage(text))
        let verb = String(text.prefix { $0.isLetter })
        #expect(message.contains(verb))
    }

    @Test(
        "A verb not followed by a JSON object is read as PartiQL",
        arguments: [
            "Scan",
            "Scan [{\"TableName\": \"Orders\"}]",
            "DeleteItem \"Orders\"",
            "select * from \"Orders\"",
            "EXISTS(SELECT * FROM \"Orders\" WHERE \"pk\" = 'a')"
        ]
    )
    func verbWithoutObjectFallsBackToPartiQL(text: String) throws {
        #expect(try DynamoDBStatement.parse(text) == .partiQL(text: text, window: DynamoDBReadWindow()))
    }

    // MARK: - Browse

    @Test("Browse reads its table, filters, match mode and columns")
    func browseParses() throws {
        let text = """
            Browse {"TableName": "Orders", "Filters": [\
            {"Attribute": "status", "Operator": "begins_with", "Value": "op", "Kind": "text", "CaseSensitive": false}, \
            {"Attribute": "total", "Operator": "BETWEEN", "Value": "1", "SecondValue": "9"}], \
            "Match": "any", "Columns": ["pk", "status"]}
            """
        let statement = try DynamoDBStatement.parse(text)
        let expected = DynamoDBBrowseRequest(
            table: "Orders",
            filters: [
                DynamoDBBrowseFilter(
                    attribute: "status", op: "BEGINS_WITH", value: "op",
                    secondValue: nil, kind: "text", caseSensitive: false
                ),
                DynamoDBBrowseFilter(
                    attribute: "total", op: "BETWEEN", value: "1",
                    secondValue: "9", kind: nil, caseSensitive: true
                )
            ],
            matchAll: false,
            columns: ["pk", "status"]
        )
        #expect(statement == .browse(expected, window: DynamoDBReadWindow()))
    }

    @Test("The Browse verb is matched without regard to case and takes a window")
    func browseVerbIsCaseInsensitive() throws {
        let statement = try DynamoDBStatement.parse("bRoWsE {\"TableName\": \"Orders\"} LIMIT 300 OFFSET 600")
        #expect(statement == .browse(
            DynamoDBBrowseRequest(table: "Orders", filters: [], matchAll: true, columns: []),
            window: DynamoDBReadWindow(limit: 300, offset: 600)
        ))
    }

    @Test(
        "Browse without a table or with an incomplete filter is refused",
        arguments: [
            "Browse {}",
            "Browse {\"TableName\": \"\"}",
            "Browse {\"TableName\": 5}",
            "Browse {\"TableName\": \"Orders\", \"Filters\": [{\"Attribute\": \"a\"}]}",
            "Browse {\"TableName\": \"Orders\", \"Filters\": [{\"Operator\": \"=\"}]}"
        ]
    )
    func incompleteBrowseIsRefused(text: String) {
        #expect(failureMessage(text) != nil)
    }

    @Test("A Browse filter value written as a JSON number keeps its digits")
    func browseNumericValueIsKept() throws {
        let json = try DynamoDBJSON.parse("""
            {"TableName": "Orders", "Filters": [{"Attribute": "total", "Operator": "=", "Value": 30}]}
            """)
        let request = try DynamoDBBrowseRequest(json: json)
        #expect(request.filters.first?.value == "30")
    }

    @Test("A Browse request survives its JSON form", arguments: [
        DynamoDBBrowseRequest(table: "Orders", filters: [], matchAll: true, columns: []),
        DynamoDBBrowseRequest(table: "Or\"ders", filters: [], matchAll: true, columns: ["pk", "a\"b"]),
        DynamoDBBrowseRequest(
            table: "Orders",
            filters: [
                DynamoDBBrowseFilter(
                    attribute: "status", op: "=", value: "open",
                    secondValue: nil, kind: "text", caseSensitive: false
                ),
                DynamoDBBrowseFilter(
                    attribute: "total", op: "BETWEEN", value: "1",
                    secondValue: "9", kind: "decimal", caseSensitive: true
                )
            ],
            matchAll: false,
            columns: []
        ),
        DynamoDBBrowseRequest(
            table: "Orders",
            filters: [
                DynamoDBBrowseFilter(
                    attribute: "note", op: "IS NULL", value: "",
                    secondValue: nil, kind: nil, caseSensitive: true
                )
            ],
            matchAll: true,
            columns: ["note"]
        )
    ])
    func browseJSONRoundTrip(request: DynamoDBBrowseRequest) throws {
        #expect(try DynamoDBBrowseRequest(json: request.json) == request)
        #expect(try DynamoDBBrowseRequest(json: DynamoDBJSON.parse(request.json.serialized())) == request)
    }

    @Test("A Browse request with no filters or columns writes only its table")
    func browseJSONOmitsEmptyParts() {
        let request = DynamoDBBrowseRequest(table: "Orders", filters: [], matchAll: true, columns: [])
        #expect(request.json == Self.ordersBody)
    }

    // MARK: - Window

    @Test("A read window after a Scan is parsed", arguments: windowCases)
    func windowAfterScan(windowCase: WindowCase) throws {
        let statement = try DynamoDBStatement.parse("Scan {\"TableName\": \"Orders\"} \(windowCase.clause)")
        #expect(statement == .apiCall(
            DynamoDBAPICall(operation: .scan, body: Self.ordersBody),
            window: windowCase.window
        ))
    }

    @Test("A read window after a Query is parsed")
    func windowAfterQuery() throws {
        let statement = try DynamoDBStatement.parse("query {\"TableName\": \"Orders\"} LIMIT 3;")
        #expect(statement == .apiCall(
            DynamoDBAPICall(operation: .query, body: Self.ordersBody),
            window: DynamoDBReadWindow(limit: 3)
        ))
    }

    @Test("Malformed or misordered text after a request is refused", arguments: malformedWindows)
    func malformedWindowIsRefused(clause: String) {
        #expect(failureMessage("Scan {\"TableName\": \"Orders\"} \(clause)") != nil)
    }

    @Test("The refusal names the action and repeats the unexpected text")
    func malformedWindowMessage() throws {
        let message = try #require(failureMessage("Scan {\"TableName\": \"Orders\"}   WHERE x = 1  "))
        #expect(message.contains("Scan"))
        #expect(message.contains("WHERE x = 1"))
    }

    @Test(
        "An action that is not a Scan or a Query takes no window",
        arguments: [DynamoDBOperation.putItem, .getItem, .deleteItem, .describeTable, .batchWriteItem, .executeStatement]
    )
    func windowOnOtherActionIsRefused(operation: DynamoDBOperation) throws {
        for clause in ["LIMIT 1", "OFFSET 1", "ORDER BY \"a\""] {
            let text = "\(operation.rawValue.lowercased()) {\"TableName\": \"Orders\"} \(clause)"
            let message = try #require(failureMessage(text))
            #expect(message.contains(operation.rawValue))
        }
    }

    // MARK: - Text

    @Test("Every statement parses back from its own text", arguments: roundTripStatements)
    func textRoundTrip(statement: DynamoDBStatement) throws {
        #expect(try DynamoDBStatement.parse(statement.text) == statement)
    }

    @Test("A statement's text is its verb, compact sorted JSON and its window, a PartiQL window on its own line")
    func textSpelling() {
        let scan = DynamoDBStatement.apiCall(
            DynamoDBAPICall(operation: .scan, body: .object(["TableName": .string("Orders"), "Limit": .number("10")])),
            window: DynamoDBReadWindow(
                order: [DynamoDBOrderTerm(attribute: "a\"b", descending: true)],
                limit: 5,
                offset: 10
            )
        )
        #expect(scan.text == "Scan {\"Limit\":10,\"TableName\":\"Orders\"} ORDER BY \"a\"\"b\" DESC LIMIT 5 OFFSET 10")

        let browse = DynamoDBStatement.browse(
            DynamoDBBrowseRequest(table: "Orders", filters: [], matchAll: true, columns: []),
            window: DynamoDBReadWindow()
        )
        #expect(browse.text == "Browse {\"TableName\":\"Orders\"}")

        let partiQL = DynamoDBStatement.partiQL(
            text: "SELECT * FROM \"Orders\"",
            window: DynamoDBReadWindow(order: [DynamoDBOrderTerm(attribute: "sk", descending: false)], offset: 3)
        )
        #expect(partiQL.text == "SELECT * FROM \"Orders\"\nORDER BY \"sk\" ASC OFFSET 3")
    }

    @Test("An empty window writes nothing")
    func emptyWindowText() {
        let window = DynamoDBReadWindow()
        #expect(window.isEmpty)
        #expect(window.text.isEmpty)
        #expect(!DynamoDBReadWindow(offset: 1).isEmpty)
        #expect(!DynamoDBReadWindow(limit: 0).isEmpty)
    }

    // MARK: - Quoting

    @Test("An identifier is wrapped in double quotes with inner quotes doubled")
    func quoteDoublesInnerQuotes() {
        #expect(DynamoDBStatement.quote("Orders") == "\"Orders\"")
        #expect(DynamoDBStatement.quote("a\"b") == "\"a\"\"b\"")
        #expect(DynamoDBStatement.quote("\"") == "\"\"\"\"")
        #expect(DynamoDBStatement.quote("") == "\"\"")
    }

    @Test(
        "A quoted identifier reads back as the same name",
        arguments: ["Orders", "a\"b", "\"\"", "it's", "with space", "-- not a comment", "/* nor this */"]
    )
    func quoteRoundTripsThroughTheTokenizer(name: String) {
        let tokens = DynamoDBPartiQL.tokens(of: DynamoDBStatement.quote(name))
        #expect(tokens.count == 1)
        #expect(tokens.first?.kind == .quotedIdentifier)
        #expect(tokens.first?.identifierValue == name)
    }
}
