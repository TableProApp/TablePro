//
//  ConnectionFormCoordinator+Extensions.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension ConnectionFormCoordinator {
    /// A list entry the person added or changed in this form was chosen on this Mac, so it is
    /// approved with the save. Entries the connection already carried keep whatever approval they
    /// had, which for an imported list is none.
    func approveEditedExtensions(for connectionId: UUID) {
        LoadableExtensionApprovalStore.shared.approve(advanced.editedExtensions, for: connectionId)
    }

    /// Test Connection loads the extensions for real, so it clears the same approval a connect does.
    /// The test runs under a throwaway id; approvals are recorded against the connection being edited
    /// and lent to that id for the length of the test, and `cleanupTestSecrets` takes them back.
    func authorizeExtensionsForTest(testConnectionId: UUID) async -> Bool {
        let store = LoadableExtensionApprovalStore.shared
        let ownerId = connectionId ?? testConnectionId
        store.approve(advanced.editedExtensions, for: ownerId)
        let owner = buildEdits().applied(to: DatabaseConnection(id: ownerId, name: ""))
        guard await LoadableExtensionPrompt.confirmIfNeeded(for: owner, approvals: store) else { return false }
        if ownerId != testConnectionId {
            store.copyApprovals(from: ownerId, to: testConnectionId)
        }
        return true
    }
}
