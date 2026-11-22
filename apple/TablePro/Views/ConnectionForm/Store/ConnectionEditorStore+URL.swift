//
//  ConnectionEditorStore+URL.swift
//  TablePro
//

import Combine
import Foundation
import TableProConnectionLibrary

struct PastedURLNotice: Equatable, Identifiable {
    let id = UUID()
    let changes: [String]

    var message: String {
        guard !changes.isEmpty else { return String(localized: "The URL matches this connection.") }
        let list = changes.formatted(.list(type: .and))
        return String(format: String(localized: "Filled from the URL: %@."), list)
    }
}

enum PastedURLOutcome: Equatable {
    case notAURL
    case applied(PastedURLNotice)
    case needsRetypeConfirmation(RetypeProposal)
}

extension ConnectionEditorStore {
    static let pasteActionName = String(localized: "Paste Connection URL")

    // Only one change that turns text without a scheme into a whole URL counts; typing never gets there in one step.
    static func pastedURL(replacing old: String, with new: String) -> String? {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.contains("://"), trimmed.contains("://"), new.count - old.count > 1 else { return nil }
        guard case .success = ConnectionURLParser.parse(trimmed) else { return nil }
        return trimmed
    }

    func setHost(_ text: String, undoManager: UndoManager?) {
        let restoring = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        if !restoring, let url = Self.pastedURL(replacing: draft.host, with: text) {
            if case .notAURL = applyPastedURL(url, undoManager: undoManager) {
                update { $0.host = text }
            }
            return
        }
        update { $0.host = text }
    }

    // Import from URL's mapping; a saved connection is never renamed, downgraded or given raw options, and a retype asks.
    @discardableResult
    func applyPastedURL(_ text: String, undoManager: UndoManager?) -> PastedURLOutcome {
        if let undoManager {
            self.undoManager = undoManager
        }
        guard case .success(let parsed) = ConnectionURLParser.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .notAURL
        }
        let snapshot = draft
        if parsed.type != draft.type {
            let proposal = proposeRetype(to: parsed.type)
            if !isNew, proposal.needsConfirmation {
                pendingPastedURL = (parsed, snapshot)
                pendingRetype = proposal
                return .needsRetypeConfirmation(proposal)
            }
            return .applied(applyPasted(parsed, snapshot: snapshot, retypeTo: parsed.type))
        }
        return .applied(applyPasted(parsed, snapshot: snapshot, retypeTo: nil))
    }

    @discardableResult
    func applyPasted(_ parsed: ParsedConnectionURL, snapshot: ConnectionDraft, retypeTo type: DatabaseType?) -> PastedURLNotice {
        isApplyingPaste = true
        defer { isApplyingPaste = false }
        if let type {
            retype(to: type)
        }
        var next = draft
        next.apply(parsed, traits: traits, policy: isNew ? .newConnection : .existingConnection, safeModeFloor: safeModeFloor)
        commit(next)
        let notice = PastedURLNotice(changes: ConnectionDraft.changedValues(from: snapshot, to: draft, traits: traits))
        pastedURLSnapshot = snapshot
        pastedURLNotice = notice
        registerPasteUndo(restoring: snapshot)
        return notice
    }

    private func registerPasteUndo(restoring snapshot: ConnectionDraft) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(snapshot) }
        }
        undoManager.setActionName(Self.pasteActionName)
    }

    // Restores the whole draft, password and type included, and registers the way back.
    func restore(_ snapshot: ConnectionDraft) {
        let current = draft
        if snapshot.type != traits.type {
            cancelTest()
            traits = ConnectionTypeTraits.live(for: snapshot.type, pluginManager: services.pluginManager)
        }
        isApplyingPaste = true
        commit(snapshot)
        isApplyingPaste = false
        dismissPastedURLNotice()
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { store in
                MainActor.assumeIsolated { store.restore(current) }
            }
            undoManager.setActionName(Self.pasteActionName)
        }
    }

    // The notice's Undo button: the snapshot, whatever the undo stack holds above it.
    func undoPastedURL() {
        guard let snapshot = pastedURLSnapshot else { return }
        undoManager?.removeAllActions(withTarget: self)
        restore(snapshot)
    }

    func dismissPastedURLNotice() {
        pastedURLNotice = nil
        pastedURLSnapshot = nil
    }

    // MARK: - Copy as URL

    // Built from the stripped edits, with no password of either kind.
    func connectionURLForCopy() -> String {
        var record = testRecord(testId: connectionId)
        let secretIds = ConnectionEditorEngine.secretFieldIds(traits, originalTraits: originalTraits)
        record.additionalFields = ConnectionSecretOptions.removingSecrets(from: record.additionalFields)
            .filter { !secretIds.contains($0.key) }
        return ConnectionURLFormatter.format(record, password: nil, sshPassword: nil, sshProfile: selectedSSHProfile)
    }
}
