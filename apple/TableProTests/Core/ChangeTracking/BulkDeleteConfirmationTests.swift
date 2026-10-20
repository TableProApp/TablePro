@testable import TablePro
import Testing

struct BulkDeleteConfirmationTests {
    private static func line(
        _ table: String,
        _ kind: CascadeEffect.Kind,
        _ count: CascadeDeletePreview.Count,
        filter: String? = "x"
    ) -> CascadeDeletePreview.Line {
        CascadeDeletePreview.Line(table: table, kind: kind, constraints: ["fk"], count: count, filterCondition: filter)
    }

    private static func confirmation(
        _ lines: [CascadeDeletePreview.Line],
        gaps: Set<CascadeDeletePreview.Gap> = []
    ) -> BulkDeleteConfirmation {
        BulkDeleteConfirmation(
            deletedRowCount: 3,
            tableName: "customers",
            preview: CascadeDeletePreview(outcome: .checked(lines: lines, gaps: gaps))
        )
    }

    private static let permanent = BulkDeleteConfirmation(deletedRowCount: 3).message

    @Test("No confirmation when nothing is being deleted")
    func testNotRequiredWithoutDeletes() {
        #expect(BulkDeleteConfirmation(deletedRowCount: 0).isRequired == false)
    }

    @Test("Confirmation required once a row is marked for deletion")
    func testRequiredWithDeletes() {
        #expect(BulkDeleteConfirmation(deletedRowCount: 1).isRequired == true)
        #expect(BulkDeleteConfirmation(deletedRowCount: 42).isRequired == true)
    }

    @Test("Title reports the row count for a bulk delete")
    func testTitleIncludesCount() {
        #expect(BulkDeleteConfirmation(deletedRowCount: 12).title.contains("12"))
    }

    @Test("Single-row title differs from the bulk title")
    func testSingleRowTitleDiffersFromBulk() {
        let single = BulkDeleteConfirmation(deletedRowCount: 1).title
        let bulk = BulkDeleteConfirmation(deletedRowCount: 2).title
        #expect(single != bulk)
    }

    @Test("Title names the table the rows are deleted from")
    func titleNamesTable() {
        let title = BulkDeleteConfirmation(deletedRowCount: 3, tableName: "customers").title
        #expect(title.contains("3"))
        #expect(title.contains("customers"))
        #expect(BulkDeleteConfirmation(deletedRowCount: 1, tableName: "customers").title.contains("customers"))
    }

    @Test("Confirm button is a specific, non-empty action title")
    func testConfirmButtonTitle() {
        #expect(BulkDeleteConfirmation(deletedRowCount: 3).confirmButtonTitle.isEmpty == false)
    }

    @Test("A table nothing references keeps the plain message and no lines")
    func noPreviewKeepsPlainPrompt() {
        let confirmation = BulkDeleteConfirmation(deletedRowCount: 3, tableName: "customers", preview: nil)
        #expect(confirmation.lines.isEmpty)
        #expect(confirmation.message == Self.permanent)
        #expect(Self.confirmation([]).message == Self.permanent)
    }

    @Test("Each affected table gets a line with its count")
    func linesCarryCounts() {
        let confirmation = Self.confirmation([
            Self.line("orders", .delete, .rows(41)),
            Self.line("order_items", .delete, .rows(1)),
            Self.line("invoices", .setNull(columns: ["customer_id"]), .rows(7)),
            Self.line("notes", .setDefault(columns: ["owner_id", "team_id"]), .rows(2))
        ])

        let texts = confirmation.lines.map(\.text)
        #expect(texts[0].contains("41") && texts[0].contains("orders"))
        #expect(texts[1].contains("1") && texts[1].contains("order_items"))
        #expect(texts[2].contains("customer_id") && texts[2].contains("7") && texts[2].contains("invoices"))
        #expect(texts[3].contains("owner_id, team_id") && texts[3].contains("notes"))
        #expect(confirmation.message != Self.permanent)
    }

    @Test("Rows that block the delete say the save will fail")
    func blockedSaveSaysItWillFail() {
        let blocked = Self.confirmation([
            Self.line("orders", .delete, .rows(4)),
            Self.line("payments", .block, .rows(12))
        ])
        let cascading = Self.confirmation([Self.line("orders", .delete, .rows(4))])

        #expect(blocked.lines.last?.text.contains("12") == true)
        #expect(blocked.lines.last?.text.contains("payments") == true)
        #expect(blocked.message != cascading.message)
    }

    @Test("A save that turns foreign key checks off does not promise to fail")
    func checksTurnedOffIsNotAFailure() {
        let lines = [Self.line("payments", .block, .rows(12))]
        let blocked = Self.confirmation(lines).message
        let unchecked = Self.confirmation(lines, gaps: [.checksTurnedOff]).message

        #expect(unchecked.hasPrefix(blocked) == false)
        #expect(unchecked.hasPrefix(Self.confirmation([Self.line("orders", .delete, .rows(1))]).message))
    }

    @Test("A count that could not be read is never shown as a number")
    func unknownCountIsSaid() {
        let confirmation = Self.confirmation([
            Self.line("orders", .delete, .unknown),
            Self.line("payments", .block, .unknown)
        ])
        let counted = Self.confirmation([Self.line("orders", .delete, .rows(4))])

        #expect(confirmation.lines.allSatisfy { line in !line.text.contains { $0.isNumber } })
        #expect(confirmation.message.count > counted.message.count)
        // An uncounted blocker may not exist, so it does not say the save will fail.
        #expect(confirmation.message.hasPrefix(counted.message))
    }

    @Test("A walk cut off at the depth limit says how far it looked")
    func truncatedWalkIsSaid() {
        let confirmation = Self.confirmation([Self.line("orders", .delete, .rows(4))], gaps: [.tablesPastDepthLimit])
        #expect(confirmation.message.contains(String(CascadeDeletePlan.maximumDepth)))
    }

    @Test("Each gap adds its own sentence")
    func everyGapIsSaid() {
        let base = Self.confirmation([Self.line("orders", .delete, .rows(4))]).message
        let gaps: [CascadeDeletePreview.Gap] = [
            .tablesPastDepthLimit, .keysNotFollowed, .otherSchemas, .openTransaction, .keyColumnsEdited, .checksTurnedOff
        ]
        let messages = gaps.map { Self.confirmation([Self.line("orders", .delete, .rows(4))], gaps: [$0]).message }

        #expect(messages.allSatisfy { $0.hasPrefix(base) && $0 != base })
        #expect(Set(messages).count == gaps.count)
    }

    @Test("Keys in other schemas that were not read are said even when nothing in this one points here")
    func otherSchemasAreSaid() {
        let confirmation = Self.confirmation([], gaps: [.otherSchemas])
        #expect(confirmation.lines.isEmpty)
        #expect(confirmation.message.hasPrefix(Self.permanent))
        #expect(confirmation.message != Self.permanent)
    }

    @Test("Keys that were not enforced or not read change the message, not the lines")
    func notEnforcedAndUnavailable() {
        let notEnforced = BulkDeleteConfirmation(
            deletedRowCount: 3, tableName: "customers", preview: CascadeDeletePreview(outcome: .notEnforced)
        )
        let unavailable = BulkDeleteConfirmation(
            deletedRowCount: 3, tableName: "customers", preview: CascadeDeletePreview(outcome: .unavailable)
        )

        #expect(notEnforced.lines.isEmpty && unavailable.lines.isEmpty)
        #expect(notEnforced.message.hasPrefix(Self.permanent) && notEnforced.message != Self.permanent)
        #expect(unavailable.message.hasPrefix(Self.permanent) && unavailable.message != Self.permanent)
        #expect(notEnforced.message != unavailable.message)
    }

    @Test("Lines keep the table and the filter that opens its rows")
    func linesKeepTheirTarget() {
        let confirmation = Self.confirmation([
            Self.line("orders", .delete, .rows(4), filter: "\"orders\".\"customer_id\" IN (1)"),
            Self.line("audit", .delete, .rows(1), filter: nil)
        ])

        #expect(confirmation.lines.map(\.table) == ["orders", "audit"])
        #expect(confirmation.lines.map(\.filterCondition) == ["\"orders\".\"customer_id\" IN (1)", nil])
    }

    @Test("A long list shows its first lines and how many more there are")
    func longListIsCapped() {
        let lines = (1...11).map { Self.line("t\($0)", .delete, .rows($0)) }
        let confirmation = Self.confirmation(lines)

        #expect(confirmation.visibleLines.count == BulkDeleteConfirmation.maximumVisibleLines)
        #expect(confirmation.hiddenLineCount == 11 - BulkDeleteConfirmation.maximumVisibleLines)
    }
}
