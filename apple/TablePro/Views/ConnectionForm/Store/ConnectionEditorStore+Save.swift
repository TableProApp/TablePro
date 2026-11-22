//
//  ConnectionEditorStore+Save.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProConnectionLibrary
import TableProPluginKit
import TableProSyncTransport

enum ConnectionEditorSaveError: Error, Equatable, LocalizedError {
    case invalid(FieldIssue)
    case libraryUnreadable
    case recordMissing
    case keychainWriteFailed
    case recordWriteFailed

    var errorDescription: String? {
        switch self {
        case .invalid(let issue):
            return issue.message
        case .libraryUnreadable:
            return String(localized: "TablePro could not read your saved connections, so it did not save over them.")
        case .recordMissing:
            return String(localized: "This connection was deleted on another device or window. Your changes were not saved.")
        case .keychainWriteFailed:
            return String(localized: "Could not save this connection's passwords to the Keychain. Your changes were not saved.")
        case .recordWriteFailed:
            return String(localized: "Could not save the connection. Check disk space and permissions, then try again.")
        }
    }
}

extension ConnectionEditorStore {
    // The window's default action: a new connection opens once stored, an edited one is only saved.
    @discardableResult
    func commit() -> Result<DatabaseConnection, ConnectionEditorSaveError> {
        save(connect: isNew)
    }

    // Preflight, secrets, record, then deletes; a new id's secrets go again when its record write fails.
    @discardableResult
    func save(connect: Bool = false) -> Result<DatabaseConnection, ConnectionEditorSaveError> {
        revealAllIssues()
        switch performSave() {
        case .success(let saved):
            saveError = nil
            finishSave(saved.record, reviewed: saved.reviewed, connect: connect)
            return .success(saved.record)
        case .failure(let error):
            saveError = error
            if case .invalid(let issue) = error {
                focus(on: issue)
            }
            return .failure(error)
        }
    }

    // `reviewed` is the record as this window showed it: the draft's edits over the record it loaded.
    private func performSave() -> Result<(record: DatabaseConnection, reviewed: DatabaseConnection), ConnectionEditorSaveError> {
        if let issue = firstBlockingIssue {
            return .failure(.invalid(issue))
        }
        guard !storage.isLibraryUnreadable else { return .failure(.libraryUnreadable) }
        var connections = storage.loadConnections()
        guard !storage.lastLoadFailed else { return .failure(.libraryUnreadable) }

        let existingIndex = connections.firstIndex { $0.id == connectionId }
        if !isNew, existingIndex == nil {
            return .failure(.recordMissing)
        }

        let saving = ConnectionEditorEngine.normalized(draft, traits)
        let edits = ConnectionEditorEngine.edits(saving, traits, originalTraits: originalTraits, context)
        var record: DatabaseConnection
        let reviewed: DatabaseConnection
        let plan: SecretWritePlan
        if let existingIndex {
            let fresh = connections[existingIndex]
            record = edits.applied(to: fresh, since: baselineEdits)
            if fresh.groupId != record.groupId {
                record.sortOrder = ConnectionStorage.nextSortOrder(in: connections, groupId: record.groupId)
            }
            reviewed = edits.applied(to: loadedRecord ?? fresh, since: baselineEdits)
            plan = ConnectionEditorEngine.secretPlan(
                saving, traits, originalTraits: originalTraits, context, since: baseline, mergedInto: record
            )
        } else {
            record = edits.applied(to: DatabaseConnection(id: connectionId, name: ""))
            record.sortOrder = ConnectionStorage.nextSortOrder(in: connections, groupId: record.groupId)
            reviewed = record
            plan = ConnectionEditorEngine.secretPlan(saving, traits, originalTraits: originalTraits, context)
        }

        let staged = storage.stagingSecretEdits(
            for: connectionId,
            deviceOnly: !record.participatesInSync,
            keeping: unreadableSecretKeys,
            unchanged: loadedSecrets
        ) {
            for write in plan.writes {
                writeSecret(write.item, value: write.value, for: connectionId)
            }
            for item in plan.stagedDeletes {
                deleteSecret(item, for: connectionId)
            }
        }
        // The Keychain may hold this attempt's values now, whether or not the record saves.
        loadedSecrets = [:]
        guard !staged.writeFailed else {
            if existingIndex == nil {
                removeEverySecret(for: connectionId)
            }
            return .failure(.keychainWriteFailed)
        }

        if let existingIndex {
            connections[existingIndex] = record
        } else {
            connections.append(record)
        }
        guard storage.saveConnections(connections) else {
            if existingIndex == nil {
                removeEverySecret(for: connectionId)
            }
            return .failure(.recordWriteFailed)
        }

        storage.applyStagedDeletions(staged)
        for item in plan.deletesAfterRecord {
            deleteSecret(item, for: connectionId)
        }
        return .success((record, reviewed))
    }

    private func finishSave(_ record: DatabaseConnection, reviewed: DatabaseConnection, connect: Bool) {
        approveSavedDefinition(record, reviewed: reviewed)
        if !record.localOnly {
            services.syncTracker.markDirty(.connection, id: record.id.uuidString)
        }
        baseline = draft
        loadedRecord = record
        baselineEdits = ConnectionEditorEngine.edits(draft, traits, originalTraits: originalTraits, context)
        dirtyBaseline = dirtyFingerprint()
        hasUnsavedChanges = false
        isClosing = true
        dismissAction?()
        services.appEvents.connectionUpdated.send(record.id)
        if connect {
            connectAction(record)
        }
    }

    // A save is the person's word for what the form showed: a destination or reference another writer added while it
    // was open still asks at connect.
    private func approveSavedDefinition(_ connection: DatabaseConnection, reviewed: DatabaseConnection) {
        LoadableExtensionApprovalStore.shared.approve(editedExtensions, for: connection.id)
        for store in approvalStores {
            store.approve(connection, asReviewed: reviewed)
        }
    }

    // Only an entry added or changed here was chosen on this Mac; an imported list keeps whatever approval it had.
    var editedExtensions: [LoadableExtension] {
        var edited: [LoadableExtension] = []
        for field in traits.fields where field.content == .loadableExtensions {
            let current = (try? LoadableExtensionList.decode(draft.fieldValues[field.id])) ?? []
            let initial = Set((try? LoadableExtensionList.decode(baseline.fieldValues[field.id])) ?? [])
            edited += current.filter { !initial.contains($0) }
        }
        return edited
    }

    var removesSyncedSecretsOnSave: Bool {
        draft.options.localOnly && context.participatesInSync
    }

    // MARK: - Secret I/O

    func writeSecret(_ item: SecretWritePlan.Item, value: String, for id: UUID) {
        switch item {
        case .password: storage.savePassword(value, for: id)
        case .sshPassword: storage.saveSSHPassword(value, for: id)
        case .sshKeyPassphrase: storage.saveKeyPassphrase(value, for: id)
        case .totpSecret: storage.saveTOTPSecret(value, for: id)
        case .sslClientKeyPassphrase: storage.saveSSLClientKeyPassphrase(value, for: id)
        case .cloudflareTokenId: storage.saveCloudflareTokenId(value, for: id)
        case .cloudflareTokenSecret: storage.saveCloudflareTokenSecret(value, for: id)
        case .cloudSQLServiceAccountKey: storage.saveCloudSQLProxyServiceAccountKey(value, for: id)
        case .socksPassword: storage.saveSOCKSProxyPassword(value, for: id)
        case .pluginField(let fieldId): storage.savePluginSecureField(value, fieldId: fieldId, for: id)
        }
    }

    func deleteSecret(_ item: SecretWritePlan.Item, for id: UUID) {
        switch item {
        case .password: storage.deletePassword(for: id)
        case .sshPassword: storage.deleteSSHPassword(for: id)
        case .sshKeyPassphrase: storage.deleteKeyPassphrase(for: id)
        case .totpSecret: storage.deleteTOTPSecret(for: id)
        case .sslClientKeyPassphrase: storage.deleteSSLClientKeyPassphrase(for: id)
        case .cloudflareTokenId: storage.deleteCloudflareTokenId(for: id)
        case .cloudflareTokenSecret: storage.deleteCloudflareTokenSecret(for: id)
        case .cloudSQLServiceAccountKey: storage.deleteCloudSQLProxyServiceAccountKey(for: id)
        case .socksPassword: storage.deleteSOCKSProxyPassword(for: id)
        case .pluginField(let fieldId): storage.deletePluginSecureField(fieldId: fieldId, for: id)
        }
    }

    // Only for an id no record holds: a new connection whose save did not land.
    private func removeEverySecret(for id: UUID) {
        let fixed: [SecretWritePlan.Item] = [
            .password, .sshPassword, .sshKeyPassphrase, .totpSecret, .sslClientKeyPassphrase,
            .cloudflareTokenId, .cloudflareTokenSecret, .cloudSQLServiceAccountKey, .socksPassword
        ]
        for item in fixed {
            deleteSecret(item, for: id)
        }
        let fieldIds = ConnectionEditorEngine.secretFieldIds(traits, originalTraits: originalTraits)
        storage.deleteAllPluginSecureFields(for: id, fieldIds: Array(fieldIds))
    }

    // MARK: - Connect

    static func connectToDatabase(_ connection: DatabaseConnection) {
        Task {
            do {
                try await TabRouter.shared.route(.openConnection(connection.id))
            } catch {
                Self.handleConnectError(error, connection: connection)
            }
        }
    }

    static func handleConnectError(_ error: Error, connection: DatabaseConnection) {
        if error is CancellationError {
            logger.info("Connection attempt cancelled for \(connection.name, privacy: .private(mask: .hash))")
            return
        }
        guard WindowManager.shared.hasOpenWindow(for: connection.id) else {
            logger.info("Connection failed after window was closed: \(error.publicLogShape, privacy: .public)")
            return
        }
        WindowManager.shared.closeWindow(for: connection.id)
        if case PluginError.pluginNotInstalled = error {
            logger.info("Plugin not installed for \(connection.type.rawValue, privacy: .public)")
            WelcomeRouter.shared.routePluginInstall(connection)
            return
        }
        logger.error("Failed to connect: \(error.publicLogShape, privacy: .public)")
        WelcomeRouter.shared.routeError(error, for: connection)
    }
}
