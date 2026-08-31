//
//  ColumnReorderPolicyTests.swift
//  TablePro
//

import Foundation
@testable import TablePro
import Testing

@Suite("Column Reorder Policy")
struct ColumnReorderPolicyTests {
    private func resolve(
        support: ColumnReorderSupport = .alter,
        isColumnsTab: Bool = true,
        isTable: Bool = true,
        canEditSchema: Bool = true,
        hasStagedChanges: Bool = false,
        isRearranged: Bool = false
    ) -> ColumnReorderAvailability {
        ColumnReorderPolicy.resolve(
            support: support,
            engineName: "PostgreSQL",
            isColumnsTab: isColumnsTab,
            isTable: isTable,
            canEditSchema: canEditSchema,
            hasStagedChanges: hasStagedChanges,
            isRearranged: isRearranged
        )
    }

    @Test("A positional engine on a clean column list can reorder")
    func alterEngineIsAvailable() {
        #expect(resolve() == .available(.alter))
    }

    @Test("A rebuild engine is available too, and says so, because the cost is decided later")
    func rebuildEngineIsAvailable() {
        #expect(resolve(support: .rebuild) == .available(.rebuild))
    }

    @Test("An engine that cannot reorder names itself in the reason")
    func unsupportedEngineExplainsItself() {
        let availability = resolve(support: .unsupported)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason?.contains("PostgreSQL") == true)
    }

    @Test("A list that has no order to change is not explained, only withheld")
    func nonColumnTabIsNotApplicable() {
        #expect(resolve(isColumnsTab: false) == .notApplicable)
        #expect(resolve(isColumnsTab: false).unavailableReason == nil)
    }

    @Test("An engine whose structure is read-only is withheld before its reorder support is read")
    func readOnlyStructureOutranksSupport() {
        let availability = resolve(support: .alter, canEditSchema: false)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason?.contains("PostgreSQL") == true)
    }

    @Test("Staged edits withhold the drag, because a reorder runs against the saved table")
    func stagedChangesWithholdTheDrag() {
        let availability = resolve(hasStagedChanges: true)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason != nil)
    }

    @Test("Staged edits on an engine that cannot reorder report the engine, not the edits")
    func unsupportedOutranksStagedChanges() {
        let availability = resolve(support: .unsupported, hasStagedChanges: true)
        #expect(availability.unavailableReason?.contains("PostgreSQL") == true)
    }

    /// A drop reports a position in what is on screen. Filtered or sorted, that is not the table's
    /// order, and the delegate hands the position over without mapping it back, so the drag is
    /// withheld rather than acted on against the wrong column.
    /// Every mechanism emits table DDL, and the SQLite one looks its target up as a table, so a
    /// view drag would end in a statement error instead of an explanation.
    @Test("A view is withheld, whatever the engine can do to a table")
    func viewWithholdsTheDrag() {
        let availability = resolve(isTable: false)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason != nil)
    }

    @Test("A filtered or sorted column list withholds the drag")
    func rearrangedListWithholdsTheDrag() {
        let availability = resolve(isRearranged: true)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason != nil)
    }

    @Test("Staged edits outrank a rearranged list, because saving is the first thing to do")
    func stagedChangesOutrankRearrangement() {
        let staged = resolve(hasStagedChanges: true, isRearranged: true)
        #expect(staged.unavailableReason == resolve(hasStagedChanges: true).unavailableReason)
    }
}
