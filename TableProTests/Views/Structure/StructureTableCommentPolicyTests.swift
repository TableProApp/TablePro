//
//  StructureTableCommentPolicyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct StructureTableCommentPolicyTests {
    private static let tablesOnly = DatabaseObjectToolEligibility.Support(commentableTypes: [.table])
    private static let tablesAndViews = DatabaseObjectToolEligibility.Support(commentableTypes: [.table, .view])

    private func resolve(
        _ kind: TableInfo.TableType = .table,
        support: DatabaseObjectToolEligibility.Support = StructureTableCommentPolicyTests.tablesAndViews,
        isReadOnly: Bool = false,
        load: MetadataLoadPhase = .loaded,
        isSaving: Bool = false
    ) -> StructureTableCommentPolicy.Field? {
        StructureTableCommentPolicy.resolve(
            objectKind: kind,
            support: support,
            isReadOnly: isReadOnly,
            load: load,
            isSaving: isSaving
        )
    }

    @Test("The bar is hidden for a kind the engine cannot comment on")
    func hiddenWithoutAStatement() {
        #expect(resolve(.view, support: Self.tablesOnly) == nil)
        #expect(resolve(.table, support: DatabaseObjectToolEligibility.Support.none) == nil)
    }

    @Test("A loaded comment on a writable connection is editable")
    func editableWhenLoaded() {
        #expect(resolve() == StructureTableCommentPolicy.Field(
            isEditable: true, placeholder: String(localized: "Optional"), unavailableReason: nil
        ))
        #expect(resolve(.view)?.isEditable == true)
    }

    @Test("The field waits for the comment to load", arguments: [MetadataLoadPhase.idle, .loading])
    func disabledWhileLoading(load: MetadataLoadPhase) {
        let field = resolve(load: load)
        #expect(field?.isEditable == false)
        #expect(field?.unavailableReason == nil)
    }

    @Test("A comment that failed to load says so and names the error")
    func failedLoadIsExplained() {
        let field = resolve(load: .failed("permission denied"))
        #expect(field?.isEditable == false)
        #expect(field?.placeholder == String(localized: "Comment Unavailable"))
        #expect(field?.unavailableReason == "permission denied")
    }

    @Test("A save in flight dims the field with the saving reason")
    func savingDims() {
        let field = resolve(isSaving: true)
        #expect(field?.isEditable == false)
        #expect(field?.unavailableReason == StructureFooterPolicy.savingReason)
    }

    @Test("Read-only Safe Mode dims the field and says why")
    func readOnlyDims() {
        let field = resolve(isReadOnly: true)
        #expect(field?.isEditable == false)
        #expect(field?.unavailableReason == String(
            localized: "Cannot save schema changes: TablePro's Safe Mode is set to read-only for this connection."
        ))
    }
}
