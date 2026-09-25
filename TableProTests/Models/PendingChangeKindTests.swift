//
//  PendingChangeKindTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct PendingChangeKindTests {
    private static let contentKinds: [TabType] = [
        .query, .table, .erDiagram, .serverDashboard, .insights, .objectSource,
    ]

    @Test("Nothing staged leaves no kind", arguments: contentKinds + [.createTable, .usersRoles])
    func nothingStaged(tabType: TabType) {
        #expect(
            PendingChangeKind.resolve(
                tabType: tabType,
                hasDataChanges: false,
                hasStructureChanges: false,
                hasCreateTablePending: false,
                hasPrincipalChanges: false,
                isFileDirty: false
            ) == nil
        )
    }

    @Test("Each source names its own kind", arguments: contentKinds)
    func eachSource(tabType: TabType) {
        let data = PendingChangeKind.resolve(
            tabType: tabType,
            hasDataChanges: true,
            hasStructureChanges: false,
            hasCreateTablePending: false,
            hasPrincipalChanges: false,
            isFileDirty: false
        )
        let structure = PendingChangeKind.resolve(
            tabType: tabType,
            hasDataChanges: false,
            hasStructureChanges: true,
            hasCreateTablePending: false,
            hasPrincipalChanges: false,
            isFileDirty: false
        )
        let file = PendingChangeKind.resolve(
            tabType: tabType,
            hasDataChanges: false,
            hasStructureChanges: false,
            hasCreateTablePending: false,
            hasPrincipalChanges: false,
            isFileDirty: true
        )

        #expect(data == .data)
        #expect(structure == .structure)
        #expect(file == .file)
    }

    /// The defect this type exists for: the commit control was dim on a Users & Roles tab with
    /// staged principals, because the one function that fed it never read that flag.
    @Test("Staged principals are a pending change on a Users & Roles tab")
    func principalsAreAPendingChange() {
        #expect(
            PendingChangeKind.resolve(
                tabType: .usersRoles,
                hasDataChanges: false,
                hasStructureChanges: false,
                hasCreateTablePending: false,
                hasPrincipalChanges: true,
                isFileDirty: false
            ) == .principals
        )
    }

    @Test("A committable definition is a pending change on a Create Table tab")
    func createTableIsAPendingChange() {
        #expect(
            PendingChangeKind.resolve(
                tabType: .createTable,
                hasDataChanges: true,
                hasStructureChanges: true,
                hasCreateTablePending: true,
                hasPrincipalChanges: true,
                isFileDirty: true
            ) == .createTable
        )
    }

    /// A Create Table tab whose definition is not yet valid stages nothing, whatever else is true
    /// elsewhere in the window.
    @Test("An incomplete definition stages nothing, whatever else is set")
    func incompleteDefinitionStagesNothing() {
        #expect(
            PendingChangeKind.resolve(
                tabType: .createTable,
                hasDataChanges: true,
                hasStructureChanges: true,
                hasCreateTablePending: false,
                hasPrincipalChanges: true,
                isFileDirty: true
            ) == nil
        )
    }

    @Test("Structure outranks data, and data outranks a dirty file", arguments: contentKinds)
    func precedence(tabType: TabType) {
        let structureOverData = PendingChangeKind.resolve(
            tabType: tabType,
            hasDataChanges: true,
            hasStructureChanges: true,
            hasCreateTablePending: false,
            hasPrincipalChanges: false,
            isFileDirty: true
        )
        let dataOverFile = PendingChangeKind.resolve(
            tabType: tabType,
            hasDataChanges: true,
            hasStructureChanges: false,
            hasCreateTablePending: false,
            hasPrincipalChanges: false,
            isFileDirty: true
        )

        #expect(structureOverData == .structure)
        #expect(dataOverFile == .data)
    }

    /// Principals belong to their own tab. A stale flag left by a tab the user closed must not
    /// light the commit control somewhere else.
    @Test("Staged principals stage nothing outside a Users & Roles tab", arguments: contentKinds)
    func principalsAreTabScoped(tabType: TabType) {
        #expect(
            PendingChangeKind.resolve(
                tabType: tabType,
                hasDataChanges: false,
                hasStructureChanges: false,
                hasCreateTablePending: false,
                hasPrincipalChanges: true,
                isFileDirty: false
            ) == nil
        )
    }

    @Test("A window with no selected tab still answers for its content sources")
    func noSelectedTab() {
        #expect(
            PendingChangeKind.resolve(
                tabType: nil,
                hasDataChanges: true,
                hasStructureChanges: false,
                hasCreateTablePending: false,
                hasPrincipalChanges: false,
                isFileDirty: false
            ) == .data
        )
        #expect(
            PendingChangeKind.resolve(
                tabType: nil,
                hasDataChanges: false,
                hasStructureChanges: false,
                hasCreateTablePending: false,
                hasPrincipalChanges: false,
                isFileDirty: false
            ) == nil
        )
    }
}
