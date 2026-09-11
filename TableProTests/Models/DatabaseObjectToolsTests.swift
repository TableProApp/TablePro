//
//  DatabaseObjectToolsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Per-object command eligibility")
struct DatabaseObjectToolEligibilityTests {
    private let support = DatabaseObjectToolEligibility.Support(
        canRefreshMaterializedViews: true,
        commentableTypes: [.table, .partitionedTable, .view, .materializedView, .foreignTable]
    )

    @Test("A view's source is its definition, so only the view kinds show DDL")
    func ddlIsViewOnly() {
        #expect(DatabaseObjectToolEligibility.canShowDDL(.view))
        #expect(DatabaseObjectToolEligibility.canShowDDL(.materializedView))
        for type in [TableInfo.TableType.table, .partitionedTable, .foreignTable, .systemTable, .externalTable] {
            #expect(!DatabaseObjectToolEligibility.canShowDDL(type))
        }
        #expect(!DatabaseObjectToolEligibility.canShowDDL(nil))
    }

    @Test("Refresh needs a materialized view, a driver statement and write access")
    func refreshRequirements() {
        #expect(DatabaseObjectToolEligibility.canRefresh(.materializedView, support: support, isReadOnly: false))
        #expect(!DatabaseObjectToolEligibility.canRefresh(.materializedView, support: support, isReadOnly: true))
        #expect(!DatabaseObjectToolEligibility.canRefresh(.view, support: support, isReadOnly: false))
        #expect(!DatabaseObjectToolEligibility.canRefresh(.materializedView, support: .none, isReadOnly: false))
        #expect(!DatabaseObjectToolEligibility.canRefresh(nil, support: support, isReadOnly: false))
    }

    @Test("Editing a comment follows the kinds the driver can comment on")
    func commentRequirements() {
        #expect(DatabaseObjectToolEligibility.canEditComment(.table, support: support, isReadOnly: false))
        #expect(DatabaseObjectToolEligibility.canEditComment(.materializedView, support: support, isReadOnly: false))
        #expect(!DatabaseObjectToolEligibility.canEditComment(.externalTable, support: support, isReadOnly: false))
        #expect(!DatabaseObjectToolEligibility.canEditComment(.table, support: support, isReadOnly: true))
        #expect(!DatabaseObjectToolEligibility.canEditComment(.table, support: .none, isReadOnly: false))
    }
}

@Suite("Materialized view refresh prompt")
struct MaterializedViewRefreshPromptTests {
    private func prompt(
        _ availability: PluginConcurrentRefreshAvailability?,
        checkFailed: Bool = false
    ) -> MaterializedViewRefreshPrompt {
        MaterializedViewRefreshPrompt(
            qualifiedName: "sales.mv",
            availability: availability,
            availabilityCheckFailed: checkFailed
        )
    }

    @Test("The prompt names the view it is about")
    func promptNamesTheView() {
        #expect(prompt(.available).messageText.contains("sales.mv"))
        #expect(prompt(.available).confirmButtonTitle == String(localized: "Refresh"))
    }

    /// The informative text has to warn about the lock, because a plain refresh holds an exclusive
    /// lock on the view for its whole duration.
    @Test("The prompt says a plain refresh blocks readers")
    func promptWarnsAboutReaders() {
        #expect(prompt(.available).informativeText.lowercased().contains("other sessions"))
    }

    @Test("The concurrent option is enabled only for a view the server would accept")
    func concurrentOptionEnablement() {
        #expect(prompt(.available).isConcurrentOptionEnabled)
        #expect(!prompt(.requiresUniqueIndex).isConcurrentOptionEnabled)
        #expect(!prompt(.requiresPopulatedView).isConcurrentOptionEnabled)
        #expect(!prompt(nil).isConcurrentOptionEnabled)
    }

    /// An engine with no concurrent refresh shows no option at all. A check that failed shows it
    /// disabled with its reason, rather than implying the engine lacks it.
    @Test("The option is absent for an engine without one and present when the check failed")
    func optionVisibility() {
        #expect(prompt(.available).showsConcurrentOption)
        #expect(prompt(.requiresUniqueIndex).showsConcurrentOption)
        #expect(!prompt(nil).showsConcurrentOption)
        #expect(prompt(nil, checkFailed: true).showsConcurrentOption)
        #expect(!prompt(nil, checkFailed: true).isConcurrentOptionEnabled)
    }

    @Test("Each unavailable reason explains itself")
    func reasonsAreExplained() {
        #expect(prompt(.requiresUniqueIndex).concurrentOptionDescription.contains("unique index"))
        #expect(prompt(.requiresPopulatedView).concurrentOptionDescription.contains("rows"))
        #expect(!prompt(nil, checkFailed: true).concurrentOptionDescription.isEmpty)
        #expect(prompt(nil).concurrentOptionDescription.isEmpty)
    }

    /// A checkbox left on by a previous state cannot ask for a refresh the server has already said
    /// it would refuse.
    @Test("A checked box is honoured only while the option is enabled")
    func checkboxIsGated() {
        #expect(prompt(.available).refreshesConcurrently(checkboxIsOn: true))
        #expect(!prompt(.available).refreshesConcurrently(checkboxIsOn: false))
        #expect(!prompt(.requiresUniqueIndex).refreshesConcurrently(checkboxIsOn: true))
        #expect(!prompt(nil, checkFailed: true).refreshesConcurrently(checkboxIsOn: true))
    }
}

@Suite("Object comment draft")
struct ObjectCommentDraftTests {
    @Test("A draft starts from the stored comment")
    func startsFromStoredComment() {
        let draft = ObjectCommentDraft(original: "daily totals")

        #expect(draft.text == "daily totals")
        #expect(!draft.hasChanges)
        #expect(draft.commentToSave == "daily totals")
        #expect(!draft.removesComment)
    }

    @Test("An object with no comment starts empty and has nothing to save")
    func startsEmptyWithoutComment() {
        let draft = ObjectCommentDraft(original: nil)

        #expect(draft.text.isEmpty)
        #expect(!draft.hasChanges)
        #expect(draft.commentToSave == nil)
        #expect(!draft.removesComment)
    }

    /// Clearing the field means removing the comment, which is the same thing PostgreSQL does with
    /// an empty string.
    @Test("Emptying the field removes the comment", arguments: ["", "   ", "\n\t"])
    func emptyingRemovesTheComment(text: String) {
        var draft = ObjectCommentDraft(original: "daily totals")
        draft.text = text

        #expect(draft.commentToSave == nil)
        #expect(draft.hasChanges)
        #expect(draft.removesComment)
    }

    @Test("Whitespace around a stored comment does not count as a change")
    func whitespaceOnlyOriginalIsNoComment() {
        let draft = ObjectCommentDraft(original: "   ")

        #expect(draft.commentToSave == nil)
        #expect(!draft.hasChanges)
    }

    @Test("Editing the text is a change, and multiple lines are kept")
    func editingIsAChange() {
        var draft = ObjectCommentDraft(original: "one")
        draft.text = "one\ntwo"

        #expect(draft.hasChanges)
        #expect(draft.commentToSave == "one\ntwo")
        #expect(!draft.removesComment)
    }
}

@MainActor
@Suite("Object source refs for views")
struct DatabaseObjectRefViewKindTests {
    private func table(_ name: String, type: TableInfo.TableType) -> TableInfo {
        TableInfo(name: name, type: type, rowCount: nil, schema: "sales")
    }

    @Test("A view and a materialized view open as object source, other kinds do not")
    func kindFromTableType() {
        #expect(DatabaseObjectKind(tableType: .view) == .view)
        #expect(DatabaseObjectKind(tableType: .materializedView) == .materializedView)
        for type in [TableInfo.TableType.table, .partitionedTable, .foreignTable, .systemTable, .externalTable] {
            #expect(DatabaseObjectKind(tableType: type) == nil)
        }
    }

    @Test("A ref built from a listing row carries the object's own database and schema")
    func refCarriesScope() {
        let ref = DatabaseObjectRef(relation: table("mv", type: .materializedView), database: "app", schema: "sales")

        #expect(ref?.kind == .materializedView)
        #expect(ref?.database == "app")
        #expect(ref?.schema == "sales")
        #expect(ref?.qualifiedName == "sales.mv")
        #expect(ref?.displayIdentity == "sales.mv")
        #expect(DatabaseObjectRef(relation: table("users", type: .table), database: "app", schema: "sales") == nil)
    }

    @Test("The view kinds map to their sidebar kind and survive a round trip")
    func kindsRoundTrip() throws {
        #expect(DatabaseObjectKind.view.sidebarObjectKind == .view)
        #expect(DatabaseObjectKind.materializedView.sidebarObjectKind == .materializedView)

        for kind in [DatabaseObjectKind.view, .materializedView] {
            let ref = DatabaseObjectRef(kind: kind, name: "mv", database: "app", schema: "sales")
            let decoded = try JSONDecoder().decode(
                DatabaseObjectRef.self,
                from: try JSONEncoder().encode(ref)
            )
            #expect(decoded == ref)
        }
    }

    @Test("The tab title names the kind")
    func tabTitleNamesTheKind() {
        let view = DatabaseObjectRef(kind: .view, name: "vw", database: "app", schema: "sales")
        let matview = DatabaseObjectRef(kind: .materializedView, name: "mv", database: "app", schema: "sales")

        #expect(QueryTabManager.objectSourceTitle(for: view).contains("sales.vw"))
        #expect(QueryTabManager.objectSourceTitle(for: matview).contains("sales.mv"))
        #expect(QueryTabManager.objectSourceTitle(for: view) != QueryTabManager.objectSourceTitle(for: matview))
    }
}
