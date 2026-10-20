import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct CascadeDeletePreviewerTests {
    private struct Failure: Error {}

    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "public")

    private static let root = CascadeDeleteRoot(
        table: "customers",
        columns: ["id", "name"],
        primaryKeyColumns: ["id"],
        rows: [[.text("1"), .text("Ann")], [.text("2"), .text("Bo")], [.text("3"), .text("Cy")]]
    )

    private static let foreignKeys: [String: [ForeignKeyInfo]] = [
        "orders": [
            ForeignKeyInfo(
                name: "fk_orders_customer", column: "customer_id", referencedTable: "customers",
                referencedColumn: "id", referencedSchema: "public", onDelete: "CASCADE"
            )
        ],
        "order_items": [
            ForeignKeyInfo(
                name: "fk_items_order", column: "order_id", referencedTable: "orders",
                referencedColumn: "id", referencedSchema: "public", onDelete: "CASCADE"
            )
        ],
        "invoices": [
            ForeignKeyInfo(
                name: "fk_invoices_customer", column: "customer_id", referencedTable: "customers",
                referencedColumn: "id", referencedSchema: "public", onDelete: "SET NULL"
            )
        ],
        "payments": [
            ForeignKeyInfo(
                name: "fk_payments_customer", column: "customer_id", referencedTable: "customers",
                referencedColumn: "id", referencedSchema: "public", onDelete: "RESTRICT"
            )
        ]
    ]

    private static func environment(
        foreignKeys: @escaping @MainActor () async throws -> [String: [ForeignKeyInfo]] = { Self.foreignKeys },
        tableNames: CascadeTableNames = CascadeTableNames(ignoresCase: false),
        otherSchemas: (@MainActor () async throws -> Bool)? = nil,
        holdsTransaction: (@MainActor () async -> Bool)? = nil,
        enforcement: (@MainActor () async throws -> Bool)? = nil,
        count: @escaping @MainActor (String) async throws -> Int
    ) -> CascadeDeletePreviewer.Environment {
        CascadeDeletePreviewer.Environment(
            slot: .schema,
            tableNames: tableNames,
            dialect: CascadeDeleteSQLTests.dialect,
            readForeignKeys: foreignKeys,
            readHasOtherSchemas: otherSchemas,
            readHoldsTransaction: holdsTransaction,
            readEnforcement: enforcement,
            count: count
        )
    }

    private static func table(of query: String) -> String {
        let afterFrom = query.components(separatedBy: "FROM \"public\".\"").dropFirst().first ?? ""
        return afterFrom.components(separatedBy: "\"").first ?? ""
    }

    @Test("Each affected table is counted, and a table with no matching rows is left out")
    func countsEveryEffect() async {
        let counts = ["orders": 41, "order_items": 112, "invoices": 7, "payments": 0]
        let preview = await CascadeDeletePreviewer.preview(
            of: Self.root,
            in: scope,
            environment: Self.environment { query in counts[Self.table(of: query)] ?? -1 }
        )

        guard case .checked(let lines, let gaps)? = preview?.outcome else {
            Issue.record("Expected a checked preview, got \(String(describing: preview))")
            return
        }
        #expect(gaps.isEmpty)
        #expect(lines.map(\.table) == ["invoices", "orders", "order_items"])
        #expect(lines.map(\.count) == [.rows(7), .rows(41), .rows(112)])
        #expect(lines.allSatisfy { $0.filterCondition != nil })
    }

    @Test("A table nothing references adds nothing to the prompt")
    func unreferencedTable() async {
        let preview = await CascadeDeletePreviewer.preview(
            of: CascadeDeleteRoot(table: "tags", columns: ["id"], primaryKeyColumns: ["id"], rows: [[.text("1")]]),
            in: scope,
            environment: Self.environment { _ in
                Issue.record("Nothing should be counted")
                return 0
            }
        )

        #expect(preview == nil)
    }

    @Test("Keys that cannot be read are reported, not taken as none")
    func unreadableKeys() async {
        let preview = await CascadeDeletePreviewer.preview(
            of: Self.root,
            in: scope,
            environment: Self.environment(foreignKeys: { throw Failure() }) { _ in 0 }
        )

        #expect(preview?.outcome == .unavailable)
    }

    @Test("A connection with foreign keys off cascades nothing, so nothing is counted")
    func enforcementOff() async {
        let preview = await CascadeDeletePreviewer.preview(
            of: Self.root,
            in: scope,
            environment: Self.environment(enforcement: { false }) { _ in
                Issue.record("Nothing should be counted")
                return 0
            }
        )

        #expect(preview?.outcome == .notEnforced)
    }

    @Test("A failed enforcement read still counts, since most sessions enforce their keys")
    func enforcementReadFailure() async {
        let preview = await CascadeDeletePreviewer.preview(
            of: Self.root,
            in: scope,
            environment: Self.environment(enforcement: { throw Failure() }) { _ in 1 }
        )

        guard case .checked(let lines, _)? = preview?.outcome else {
            Issue.record("Expected a checked preview")
            return
        }
        #expect(lines.count == 4)
    }

    @Test("A count that fails leaves that table uncounted and the rest counted")
    func failedCountIsUnknown() async {
        let preview = await CascadeDeletePreviewer.preview(
            of: Self.root,
            in: scope,
            environment: Self.environment { query in
                if Self.table(of: query) == "orders" { throw Failure() }
                return 2
            }
        )

        guard case .checked(let lines, _)? = preview?.outcome else {
            Issue.record("Expected a checked preview")
            return
        }
        #expect(lines.first { $0.table == "orders" }?.count == .unknown)
        #expect(lines.first { $0.table == "payments" }?.count == .rows(2))
    }

    @Test("Counts still running when the budget runs out are reported as not counted")
    func budgetEndsTheWait() async {
        let clock = ManualClock()
        let gate = AsyncGate()
        let previewTask = Task { @MainActor in
            await CascadeDeletePreviewer.preview(
                of: Self.root,
                in: scope,
                environment: Self.environment { query in
                    if Self.table(of: query) == "invoices" { return 5 }
                    await gate.wait()
                    return 9
                },
                budget: .seconds(5),
                clock: clock
            )
        }
        await gate.arrived(1)
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(5))
        let preview = await previewTask.value
        await gate.open()

        guard case .checked(let lines, _)? = preview?.outcome else {
            Issue.record("Expected a checked preview")
            return
        }
        #expect(lines.first { $0.table == "invoices" }?.count == .rows(5))
        #expect(lines.filter { $0.table != "invoices" }.allSatisfy { $0.count == .unknown })
    }

    @Test("A condition the raw filter would refuse is not offered for showing")
    func unsafeFilterIsNotOffered() async {
        let root = CascadeDeleteRoot(
            table: "customers", columns: ["id"], primaryKeyColumns: ["id"], rows: [[.text("a/*b")]]
        )
        let preview = await CascadeDeletePreviewer.preview(
            of: root,
            in: scope,
            environment: Self.environment { _ in 1 }
        )

        guard case .checked(let lines, _)? = preview?.outcome else {
            Issue.record("Expected a checked preview")
            return
        }
        #expect(lines.allSatisfy { $0.filterCondition == nil })
        #expect(lines.allSatisfy { $0.count == .rows(1) })
    }

    @Test("A key that spells its parent in another case still reaches it where names ignore case")
    func caseInsensitiveParentName() async {
        let foreignKeys: [String: [ForeignKeyInfo]] = [
            "orders": [
                ForeignKeyInfo(
                    name: "fk_orders_customer", column: "customer_id", referencedTable: "CUSTOMERS",
                    referencedColumn: "id", referencedSchema: "public", onDelete: "CASCADE"
                )
            ]
        ]
        let folded = await CascadeDeletePreviewer.preview(
            of: Self.root,
            in: scope,
            environment: Self.environment(foreignKeys: { foreignKeys }, tableNames: CascadeTableNames(ignoresCase: true)) { _ in 4 }
        )
        let exact = await CascadeDeletePreviewer.preview(
            of: Self.root,
            in: scope,
            environment: Self.environment(foreignKeys: { foreignKeys }) { _ in 4 }
        )

        #expect(folded?.outcome == .checked(
            lines: [
                CascadeDeletePreview.Line(
                    table: "orders",
                    kind: .delete,
                    constraints: ["fk_orders_customer"],
                    count: .rows(4),
                    filterCondition: #"EXISTS (SELECT 1 FROM "public"."customers" cascade_1 WHERE cascade_1."id" = "orders"."customer_id""#
                        + #" AND (cascade_1."id" IN ('1', '2', '3')))"#
                )
            ],
            gaps: []
        ))
        #expect(exact == nil)
    }

    @Test("Other schemas whose keys were not read are reported, even for a table nothing here references")
    func otherSchemasAreReported() async {
        let unreferenced = await CascadeDeletePreviewer.preview(
            of: CascadeDeleteRoot(table: "tags", columns: ["id"], primaryKeyColumns: ["id"], rows: [[.text("1")]]),
            in: scope,
            environment: Self.environment(otherSchemas: { true }) { _ in 0 }
        )
        let referenced = await CascadeDeletePreviewer.preview(
            of: Self.root,
            in: scope,
            environment: Self.environment(otherSchemas: { throw Failure() }) { _ in 1 }
        )
        let alone = await CascadeDeletePreviewer.preview(
            of: CascadeDeleteRoot(table: "tags", columns: ["id"], primaryKeyColumns: ["id"], rows: [[.text("1")]]),
            in: scope,
            environment: Self.environment(otherSchemas: { false }) { _ in 0 }
        )

        #expect(unreferenced?.outcome == .checked(lines: [], gaps: [.otherSchemas]))
        guard case .checked(let lines, let gaps)? = referenced?.outcome else {
            Issue.record("Expected a checked preview")
            return
        }
        #expect(lines.count == 4)
        #expect(gaps == [.otherSchemas])
        #expect(alone == nil)
    }

    @Test("Counts read beside an open transaction say they cannot see its rows")
    func openTransactionIsSaid() async {
        let preview = await CascadeDeletePreviewer.preview(
            of: Self.root,
            in: scope,
            environment: Self.environment(holdsTransaction: { true }) { _ in 1 }
        )

        guard case .checked(let lines, let gaps)? = preview?.outcome else {
            Issue.record("Expected a checked preview")
            return
        }
        #expect(lines.count == 4)
        #expect(gaps == [.openTransaction])
    }

    @Test("A save that turns checks off, or edits key columns, still counts and says what it leaves out")
    func saveSideGaps() async {
        var environment = Self.environment { _ in 1 }
        environment.checksTurnedOffBySave = true
        let checksOff = await CascadeDeletePreviewer.preview(of: Self.root, in: scope, environment: environment)
        let edited = await CascadeDeletePreviewer.preview(
            of: CascadeDeleteRoot(
                table: "customers", columns: ["id"], primaryKeyColumns: ["id"], rows: [[.text("1")]], editedColumns: ["id"]
            ),
            in: scope,
            environment: Self.environment { _ in 1 }
        )

        guard case .checked(let lines, let gaps)? = checksOff?.outcome else {
            Issue.record("Expected a checked preview")
            return
        }
        #expect(lines.count == 4)
        #expect(gaps == [.checksTurnedOff])
        guard case .checked(_, let editedGaps)? = edited?.outcome else {
            Issue.record("Expected a checked preview")
            return
        }
        #expect(editedGaps == [.keyColumnsEdited])
    }

    @Test("Rows a cascade deletes anyway are not counted as blocking the delete")
    func cascadeDeletedRowsDoNotBlock() async {
        let foreignKeys: [String: [ForeignKeyInfo]] = [
            "orders": [
                ForeignKeyInfo(
                    name: "fk_orders_customer", column: "customer_id", referencedTable: "customers",
                    referencedColumn: "id", referencedSchema: "public", onDelete: "CASCADE"
                )
            ],
            "notes": [
                ForeignKeyInfo(
                    name: "fk_notes_order", column: "order_id", referencedTable: "orders",
                    referencedColumn: "id", referencedSchema: "public", onDelete: "CASCADE"
                ),
                ForeignKeyInfo(
                    name: "fk_notes_customer", column: "customer_id", referencedTable: "customers",
                    referencedColumn: "id", referencedSchema: "public", onDelete: "NO ACTION"
                )
            ]
        ]
        var blockQuery = ""
        _ = await CascadeDeletePreviewer.preview(
            of: Self.root,
            in: scope,
            environment: Self.environment(foreignKeys: { foreignKeys }) { query in
                if query.contains("= \"notes\".\"customer_id\"") { blockQuery = query }
                return 1
            }
        )

        #expect(blockQuery.contains("CASE WHEN EXISTS"))
        #expect(blockQuery.contains("= \"notes\".\"order_id\""))
    }

    @Test("Table names ignore case on the engines that look tables up that way")
    func tableNameFolding() {
        #expect(CascadeTableNames(databaseType: .sqlite).ignoresCase)
        #expect(CascadeTableNames(databaseType: .mssql).ignoresCase)
        #expect(CascadeTableNames(databaseType: .postgresql).ignoresCase == false)
        #expect(CascadeTableNames(databaseType: .mysql).ignoresCase == false)
    }

    @Test("Enforcement is read where a session can turn its keys off")
    func enforcementQueries() {
        #expect(CascadeDeletePreviewer.foreignKeyEnforcementQuery(for: .sqlite) == "PRAGMA foreign_keys")
        #expect(CascadeDeletePreviewer.foreignKeyEnforcementQuery(for: .mysql) == "SELECT @@foreign_key_checks")
        #expect(CascadeDeletePreviewer.foreignKeyEnforcementQuery(for: .mariadb) == "SELECT @@foreign_key_checks")
        #expect(CascadeDeletePreviewer.foreignKeyEnforcementQuery(for: .postgresql) == nil)
        #expect(CascadeDeletePreviewer.foreignKeyEnforcementQuery(for: .mssql) == nil)
    }
}
