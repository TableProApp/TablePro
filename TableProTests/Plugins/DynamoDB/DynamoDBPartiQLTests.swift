import Foundation
import TableProPluginKit
import Testing

struct DynamoDBPartiQLTests {
    struct KindCase: Sendable, CustomTestStringConvertible {
        let statement: String
        let kind: DynamoDBPartiQL.Kind

        var testDescription: String { statement }
    }

    struct TargetCase: Sendable, CustomTestStringConvertible {
        let statement: String
        let table: String
        let index: String?

        var testDescription: String { statement }
    }

    struct SplitCase: Sendable, CustomTestStringConvertible {
        let statement: String
        let remaining: String
        let window: DynamoDBReadWindow

        var testDescription: String { statement }
    }

    struct RolesCase: Sendable, CustomTestStringConvertible {
        let statement: String
        let roles: [DynamoDBPartiQL.ParameterRole]

        var testDescription: String { statement }
    }

    static let kindCases: [KindCase] = [
        KindCase(statement: "SELECT * FROM \"Orders\"", kind: .select),
        KindCase(statement: "  select * from Orders", kind: .select),
        KindCase(statement: "-- note\nINSERT INTO \"Orders\" VALUE {'pk': 'a'}", kind: .insert),
        KindCase(statement: "/* edit */ Update \"Orders\" SET \"a\" = 1 WHERE \"pk\" = 'a'", kind: .update),
        KindCase(statement: "delete from \"Orders\" where \"pk\" = 'a'", kind: .delete),
        KindCase(statement: "EXISTS(SELECT * FROM \"Orders\" WHERE \"pk\" = 'a')", kind: .other),
        KindCase(statement: "\"SELECT\" * FROM \"Orders\"", kind: .other),
        KindCase(statement: "'SELECT'", kind: .other),
        KindCase(statement: "", kind: .other)
    ]

    static let targetCases: [TargetCase] = [
        TargetCase(statement: "SELECT * FROM \"Orders\"", table: "Orders", index: nil),
        TargetCase(
            statement: "SELECT * FROM \"Orders\".\"ByCustomer\" WHERE \"customer\" = 'c1'",
            table: "Orders", index: "ByCustomer"
        ),
        TargetCase(
            statement: "SELECT \"a\" FROM \"My \"\"Quoted\"\" Table\".\"By \"\"X\"\"\"",
            table: "My \"Quoted\" Table", index: "By \"X\""
        ),
        TargetCase(statement: "select * from orders.bycustomer", table: "orders", index: "bycustomer"),
        TargetCase(statement: "SELECT * FROM \"Orders\" WHERE \"x\" = 'FROM \"Other\"'", table: "Orders", index: nil),
        TargetCase(statement: "INSERT INTO \"Or\"\"ders\" VALUE {'pk': 'a'}", table: "Or\"ders", index: nil),
        TargetCase(statement: "UPDATE \"Orders\" SET \"a\" = 1 WHERE \"pk\" = 'a'", table: "Orders", index: nil),
        TargetCase(statement: "UPDATE \"a\"\"b\" REMOVE \"c\" WHERE \"pk\" = 'a'", table: "a\"b", index: nil),
        TargetCase(statement: "DELETE FROM \"Orders\" WHERE \"pk\" = 'a'", table: "Orders", index: nil),
        TargetCase(statement: "-- which table\nDELETE FROM \"Orders\" WHERE \"pk\" = 'a'", table: "Orders", index: nil)
    ]

    static let splitCases: [SplitCase] = [
        SplitCase(
            statement: "SELECT * FROM \"Orders\" LIMIT 10",
            remaining: "SELECT * FROM \"Orders\"",
            window: DynamoDBReadWindow(limit: 10)
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\"   LIMIT 10 OFFSET 20",
            remaining: "SELECT * FROM \"Orders\"",
            window: DynamoDBReadWindow(limit: 10, offset: 20)
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" OFFSET 20",
            remaining: "SELECT * FROM \"Orders\"",
            window: DynamoDBReadWindow(offset: 20)
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" WHERE \"pk\" = 'a' ORDER BY \"sk\" DESC",
            remaining: "SELECT * FROM \"Orders\" WHERE \"pk\" = 'a'",
            window: DynamoDBReadWindow(order: [DynamoDBOrderTerm(attribute: "sk", descending: true)])
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" ORDER BY \"a\" DESC, b, \"c\" ASC LIMIT 5 OFFSET 1",
            remaining: "SELECT * FROM \"Orders\"",
            window: DynamoDBReadWindow(
                order: [
                    DynamoDBOrderTerm(attribute: "a", descending: true),
                    DynamoDBOrderTerm(attribute: "b", descending: false),
                    DynamoDBOrderTerm(attribute: "c", descending: false)
                ],
                limit: 5,
                offset: 1
            )
        ),
        SplitCase(
            statement: "select * from \"Orders\" order by \"a\"\"b\" asc limit 3",
            remaining: "select * from \"Orders\"",
            window: DynamoDBReadWindow(order: [DynamoDBOrderTerm(attribute: "a\"b", descending: false)], limit: 3)
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" WHERE \"a\" IN [1, 2] LIMIT 7",
            remaining: "SELECT * FROM \"Orders\" WHERE \"a\" IN [1, 2]",
            window: DynamoDBReadWindow(limit: 7)
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" WHERE \"a\" IN (SELECT \"b\" FROM \"Other\" ORDER BY \"b\")",
            remaining: "SELECT * FROM \"Orders\" WHERE \"a\" IN (SELECT \"b\" FROM \"Other\" ORDER BY \"b\")",
            window: DynamoDBReadWindow()
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" WHERE \"a\" IN (SELECT \"b\" FROM \"Other\" LIMIT 5)",
            remaining: "SELECT * FROM \"Orders\" WHERE \"a\" IN (SELECT \"b\" FROM \"Other\" LIMIT 5)",
            window: DynamoDBReadWindow()
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" ORDER BY \"doc\".\"n\"",
            remaining: "SELECT * FROM \"Orders\" ORDER BY \"doc\".\"n\"",
            window: DynamoDBReadWindow()
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" LIMIT ?",
            remaining: "SELECT * FROM \"Orders\" LIMIT ?",
            window: DynamoDBReadWindow()
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" WHERE \"a\" = 'x LIMIT 5'",
            remaining: "SELECT * FROM \"Orders\" WHERE \"a\" = 'x LIMIT 5'",
            window: DynamoDBReadWindow()
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" WHERE \"a\" = 'ORDER BY \"b\" DESC'",
            remaining: "SELECT * FROM \"Orders\" WHERE \"a\" = 'ORDER BY \"b\" DESC'",
            window: DynamoDBReadWindow()
        ),
        SplitCase(
            statement: "SELECT * FROM \"Orders\" LIMIT 5 -- first page",
            remaining: "SELECT * FROM \"Orders\"",
            window: DynamoDBReadWindow(limit: 5)
        )
    ]

    static let untouchedStatements: [String] = [
        "DELETE FROM \"Orders\" WHERE \"pk\" = 'a' LIMIT 5",
        "UPDATE \"Orders\" SET \"a\" = 1 WHERE \"pk\" = 'a' ORDER BY \"a\" DESC",
        "INSERT INTO \"Orders\" VALUE {'pk': 'a'} OFFSET 3  ",
        "EXISTS(SELECT * FROM \"Orders\" LIMIT 1)"
    ]

    static let rolesCases: [RolesCase] = [
        RolesCase(
            statement: """
                UPDATE "Orders" SET "name" = ?, "total" = ? REMOVE "note" \
                WHERE "pk" = ? AND "sk" = ? AND "name" = ? AND "total" = ?
                """,
            roles: [
                .assigned(DynamoDBAttributePath(attribute: "name")), .assigned(DynamoDBAttributePath(attribute: "total")),
                .compared(DynamoDBAttributePath(attribute: "pk")),
                .compared(DynamoDBAttributePath(attribute: "sk")),
                .compared(DynamoDBAttributePath(attribute: "name")),
                .compared(DynamoDBAttributePath(attribute: "total"))
            ]
        ),
        RolesCase(
            statement: "INSERT INTO \"Orders\" VALUE {'a': ?, 'b''c': ?}",
            roles: [.inserted("a"), .inserted("b'c")]
        ),
        RolesCase(
            statement: "SELECT * FROM \"Orders\" WHERE \"a\" IN [?, ?]",
            roles: [.compared(DynamoDBAttributePath(attribute: "a")), .compared(DynamoDBAttributePath(attribute: "a"))]
        ),
        RolesCase(
            statement: "SELECT * FROM \"Orders\" WHERE contains(\"name\", ?)",
            roles: [.compared(DynamoDBAttributePath(attribute: "name"))]
        ),
        RolesCase(
            statement: "SELECT * FROM \"Orders\" WHERE \"n\" BETWEEN ? AND ?",
            roles: [.compared(DynamoDBAttributePath(attribute: "n")), .compared(DynamoDBAttributePath(attribute: "n"))]
        ),
        RolesCase(
            statement: "SELECT * FROM \"Orders\" WHERE \"pk\" = ? AND begins_with(\"sk\", ?) OR \"x\" <> ?",
            roles: [
                .compared(DynamoDBAttributePath(attribute: "pk")),
                .compared(DynamoDBAttributePath(attribute: "sk")),
                .compared(DynamoDBAttributePath(attribute: "x"))
            ]
        ),
        RolesCase(
            statement: "UPDATE \"Orders\" SET \"a\"\"b\" = ? WHERE \"pk\" = ?",
            roles: [.assigned(DynamoDBAttributePath(attribute: "a\"b")), .compared(DynamoDBAttributePath(attribute: "pk"))]
        ),
        RolesCase(
            statement: "UPDATE \"Orders\" SET \"WHERE\" = ?, \"in\" = ? WHERE \"pk\" = ? AND \"is\" = ?",
            roles: [
                .assigned(DynamoDBAttributePath(attribute: "WHERE")),
                .assigned(DynamoDBAttributePath(attribute: "in")),
                .compared(DynamoDBAttributePath(attribute: "pk")),
                .compared(DynamoDBAttributePath(attribute: "is"))
            ]
        ),
        RolesCase(
            statement: "UPDATE \"Orders\" SET \"doc\".\"n\"[0] = ? WHERE \"pk\" = ?",
            roles: [
                .assigned(DynamoDBAttributePath(segments: [.name("doc"), .name("n"), .index(0)])),
                .compared(DynamoDBAttributePath(attribute: "pk"))
            ]
        ),
        RolesCase(
            statement: "UPDATE \"Orders\" SET \"items\" = list_append(\"items\", ?) WHERE \"pk\" = ?",
            roles: [.assigned(DynamoDBAttributePath(attribute: "items")), .compared(DynamoDBAttributePath(attribute: "pk"))]
        ),
        RolesCase(
            statement: "SELECT * FROM \"Orders\" WHERE \"a\" = '?' AND \"b\" = ?",
            roles: [.compared(DynamoDBAttributePath(attribute: "b"))]
        ),
        RolesCase(
            statement: "UPDATE \"Orders\" SET \"a\" = 1 WHERE \"pk\" = 'x'",
            roles: []
        )
    ]

    // MARK: - Kind

    @Test("The first word decides the statement kind", arguments: kindCases)
    func kind(kindCase: KindCase) {
        #expect(DynamoDBPartiQL.kind(of: kindCase.statement) == kindCase.kind)
    }

    // MARK: - Target

    @Test("The target table and index are read from the statement", arguments: targetCases)
    func target(targetCase: TargetCase) throws {
        let target = try #require(DynamoDBPartiQL.target(of: targetCase.statement))
        #expect(target.table == targetCase.table)
        #expect(target.index == targetCase.index)
    }

    @Test(
        "A statement that names no table has no target",
        arguments: ["", "SELECT 1", "SELECT * FROM", "UPDATE", "INSERT \"Orders\"", "EXISTS(SELECT * FROM \"Orders\")"]
    )
    func noTarget(statement: String) {
        #expect(DynamoDBPartiQL.target(of: statement) == nil)
    }

    // MARK: - RETURNING

    @Test(
        "A RETURNING clause is found in any case",
        arguments: [
            "DELETE FROM \"Orders\" WHERE \"pk\" = ? RETURNING ALL OLD *",
            "UPDATE \"Orders\" SET \"a\" = 1 WHERE \"pk\" = 'a' returning all new *"
        ]
    )
    func hasReturning(statement: String) {
        #expect(DynamoDBPartiQL.hasReturning(statement))
    }

    @Test(
        "RETURNING inside a string, a quoted name or a comment is not a clause",
        arguments: [
            "DELETE FROM \"Orders\" WHERE \"pk\" = 'RETURNING ALL OLD *'",
            "UPDATE \"Orders\" SET \"RETURNING\" = 1 WHERE \"pk\" = 'a'",
            "DELETE FROM \"Orders\" WHERE \"pk\" = 'a' -- RETURNING ALL OLD *",
            "DELETE FROM \"Orders\" WHERE \"pk\" = 'a' /* RETURNING ALL OLD * */",
            "DELETE FROM \"Orders\" WHERE \"pk\" = 'a'"
        ]
    )
    func hasNoReturning(statement: String) {
        #expect(!DynamoDBPartiQL.hasReturning(statement))
    }

    // MARK: - WHERE

    @Test(
        "An equality or IN on the attribute fixes it",
        arguments: [
            "SELECT * FROM \"Orders\" WHERE \"pk\" = 'a'",
            "SELECT * FROM \"Orders\" WHERE \"pk\" IN ['a', 'b']",
            "SELECT * FROM \"Orders\" WHERE \"sk\" > 3 AND \"pk\" = ?",
            "select * from Orders where pk = 'a'",
            "SELECT * FROM \"Orders\" WHERE (\"pk\" = 'a' AND \"sk\" > 1)",
            "SELECT * FROM \"Orders\" WHERE \"pk\" = 'a' AND (\"sk\" = 1 OR \"sk\" = 2)",
            "SELECT * FROM \"Orders\" WHERE ((\"pk\" = 'a')) AND \"sk\" > 1",
            "SELECT * FROM \"Orders\" WHERE \"sk\" > 1 AND (\"status\" = 'open' AND \"pk\" = 'a')"
        ]
    )
    func whereFixes(statement: String) {
        #expect(DynamoDBPartiQL.whereFixes("pk", in: statement))
    }

    @Test(
        "A range, a function, a string or a missing WHERE does not fix the attribute",
        arguments: [
            "SELECT * FROM \"Orders\"",
            "SELECT \"pk\" FROM \"Orders\" WHERE \"sk\" = 1",
            "SELECT * FROM \"Orders\" WHERE \"pk\" > 'a'",
            "SELECT * FROM \"Orders\" WHERE \"pk\" <> 'a'",
            "SELECT * FROM \"Orders\" WHERE begins_with(\"pk\", 'a')",
            "SELECT * FROM \"Orders\" WHERE \"other\" = 'pk'",
            "SELECT * FROM \"Orders\" WHERE \"PK\" = 'a'",
            "SELECT * FROM \"Orders\" WHERE NOT \"pk\" = 'a'",
            "SELECT * FROM \"Orders\" WHERE NOT (\"pk\" = 'a')",
            "SELECT * FROM \"Orders\" WHERE (\"pk\" = 'a' OR \"sk\" = 1)",
            "SELECT * FROM \"Orders\" WHERE \"sk\" = 1 AND (\"status\" = 'open' OR \"pk\" = 'a')",
            "SELECT * FROM \"Orders\" WHERE size(\"pk\") = 1"
        ]
    )
    func whereDoesNotFix(statement: String) {
        #expect(!DynamoDBPartiQL.whereFixes("pk", in: statement))
    }

    @Test("An equality joined to the rest of the WHERE clause by a top-level OR does not fix the attribute")
    func whereWithTopLevelOrDoesNotFix() {
        #expect(!DynamoDBPartiQL.whereFixes("pk", in: "SELECT * FROM \"Orders\" WHERE \"pk\" = 'a' OR \"status\" = 'open'"))
        #expect(!DynamoDBPartiQL.whereFixes("pk", in: "SELECT * FROM \"Orders\" WHERE \"status\" = 'open' OR \"pk\" = 'a'"))
    }

    @Test("An equality on a nested attribute of the same name does not fix the top-level attribute")
    func whereOnNestedPathDoesNotFix() {
        #expect(!DynamoDBPartiQL.whereFixes("pk", in: "SELECT * FROM \"Orders\" WHERE \"doc\".\"pk\" = 'a'"))
    }

    // MARK: - Trailing window

    @Test("A SELECT's trailing ORDER BY, LIMIT and OFFSET are split off", arguments: splitCases)
    func splitTrailingWindow(splitCase: SplitCase) {
        let split = DynamoDBPartiQL.splitTrailingWindow(splitCase.statement)
        #expect(split.statement == splitCase.remaining)
        #expect(split.window == splitCase.window)
    }

    @Test("A statement that is not a SELECT is returned untouched", arguments: untouchedStatements)
    func nonSelectIsUntouched(statement: String) {
        let split = DynamoDBPartiQL.splitTrailingWindow(statement)
        #expect(split.statement == statement)
        #expect(split.window.isEmpty)
    }

    @Test("A negative LIMIT or OFFSET never becomes a window", arguments: [
        "SELECT * FROM \"Orders\" LIMIT -1",
        "SELECT * FROM \"Orders\" LIMIT 5 OFFSET -2",
        "SELECT * FROM \"Orders\" OFFSET -2"
    ])
    func negativeWindowIsNotTaken(statement: String) {
        let window = DynamoDBPartiQL.splitTrailingWindow(statement).window
        #expect((window.limit ?? 0) >= 0)
        #expect(window.offset >= 0)
    }

    @Test("A comment written straight after a number still ends the statement")
    func commentAfterNumber() {
        let split = DynamoDBPartiQL.splitTrailingWindow("SELECT * FROM \"Orders\" LIMIT 5-- first page")
        #expect(split.statement == "SELECT * FROM \"Orders\"")
        #expect(split.window == DynamoDBReadWindow(limit: 5))
    }

    // MARK: - Parameter roles

    @Test("Each parameter's role is read from the words around it", arguments: rolesCases)
    func parameterRoles(rolesCase: RolesCase) {
        #expect(DynamoDBPartiQL.parameterRoles(in: rolesCase.statement) == rolesCase.roles)
    }

    @Test("Parameters inside comments are not counted")
    func parameterRolesIgnoreComments() {
        let statement = """
            UPDATE "Orders" SET "a" = ? -- , "b" = ? it's "odd"
            /* , "c" = ?
               WHERE "d" = ? */ WHERE "pk" = ? /* AND "e" = ? */
            """
        #expect(DynamoDBPartiQL.parameterRoles(in: statement) == [
            .assigned(DynamoDBAttributePath(attribute: "a")),
            .compared(DynamoDBAttributePath(attribute: "pk"))
        ])
    }

    // MARK: - Tokenizer

    @Test("Quoted names and strings are unescaped and comments dropped")
    func tokenizer() {
        let tokens = DynamoDBPartiQL.tokens(of: "SELECT \"a\"\"b\" -- c\nFROM /* d */ 'e''f' [?] -1.5e3 <>")
        #expect(tokens.map(\.kind) == [
            .word, .quotedIdentifier, .word, .string, .symbol, .parameter, .symbol, .number, .symbol
        ])
        #expect(tokens.map(\.text) == ["SELECT", "a\"b", "FROM", "e'f", "[", "?", "]", "-1.5e3", "<>"])
        #expect(tokens.map(\.depth) == [0, 0, 0, 0, 0, 1, 0, 0, 0])
    }

    @Test("An unterminated comment or string runs to the end of the text")
    func unterminatedRegions() {
        #expect(DynamoDBPartiQL.tokens(of: "SELECT /* never closed ?").map(\.text) == ["SELECT"])
        let tokens = DynamoDBPartiQL.tokens(of: "SELECT 'never closed ?")
        #expect(tokens.map(\.kind) == [.word, .string])
        #expect(tokens.last?.text == "never closed ?")
    }
}
