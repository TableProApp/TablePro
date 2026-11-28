//
//  ConnectionEditorStore+TeamCopy.swift
//  TablePro
//

import Foundation

// An owner's, admin's or editor's edit of a Team Library connection. The form shows the team's copy with what the
// team's envelopes opened to, and Save publishes the edit back to the team, never to this Mac's library.
internal struct TeamCopyTarget {
    let original: TeamLibraryConnection
    // Nil when the team's secrets could not be read: Save then leaves the team's envelopes as they are unless a
    // secret was typed.
    let secrets: [ConnectionSecretItem: String]?
}

// The copy and its secrets, read before the window opens, since the form loads in one pass.
@MainActor
internal final class TeamCopyEditStage {
    static let shared = TeamCopyEditStage()

    private var staged: [String: TeamCopyTarget] = [:]

    func stage(_ target: TeamCopyTarget) {
        staged[Self.key(target.original.teamID, target.original.id)] = target
    }

    func consume(teamID: String, itemID: String) -> TeamCopyTarget? {
        staged.removeValue(forKey: Self.key(teamID, itemID))
    }

    private static func key(_ teamID: String, _ itemID: String) -> String {
        "\(teamID)/\(itemID)"
    }
}

extension ConnectionEditorStore {
    func loadTeamCopy(_ target: TeamCopyTarget?) {
        guard let target else {
            isRecordMissing = true
            baseline = draft
            refreshDerivedState()
            return
        }
        let record = target.original.connection
        traits = ConnectionTypeTraits.live(for: record.type, pluginManager: services.pluginManager)
        originalTraits = traits
        context.originalType = record.type
        context.savedName = record.name
        var secrets = DraftSecrets()
        secrets.password = target.secrets?[.password]
        secrets.sshPassword = target.secrets?[.sshPassword]
        secrets.sshKeyPassphrase = target.secrets?[.sshKeyPassphrase]
        secrets.totpSecret = target.secrets?[.totpSecret]
        secrets.sslClientKeyPassphrase = target.secrets?[.sslClientKeyPassphrase]
        draft = ConnectionDraft.loaded(from: record, secrets: secrets, traits: traits)
        baseline = draft
        loadedRecord = record
        baselineEdits = ConnectionEditorEngine.edits(draft, traits, originalTraits: originalTraits, context)
        dirtyBaseline = dirtyFingerprint()
    }

    // The publish answers later, so the window stays until the team took the edit or said why not.
    func saveTeamCopy(_ target: TeamCopyTarget) -> Result<DatabaseConnection, ConnectionEditorSaveError> {
        if let issue = firstBlockingIssue {
            saveError = .invalid(issue)
            focus(on: issue)
            return .failure(.invalid(issue))
        }
        guard !isPublishingTeamCopy else { return .failure(.teamPublishInFlight) }
        let saving = ConnectionEditorEngine.normalized(draft, traits)
        let edits = ConnectionEditorEngine.edits(saving, traits, originalTraits: originalTraits, context)
        let record = enforcingInvariants(edits.applied(to: target.original.connection, since: baselineEdits)).record
        let secrets = teamSecrets(of: saving, loaded: target.secrets)
        saveError = nil
        isPublishingTeamCopy = true
        let library = teamLibrary
        Task { [weak self] in
            let outcome: TeamLibraryPublishOutcome
            do throws(TeamLibraryPublishError) {
                outcome = .finished(try await library.publishConnectionEdit(record, of: target.original, secrets: secrets))
            } catch {
                outcome = .failed(error)
            }
            self?.finishTeamPublish(outcome)
        }
        return .failure(.teamPublishInFlight)
    }

    // Every secret the form holds once the team's opened or one was typed; nil keeps the team's envelopes.
    func teamSecrets(
        of saving: ConnectionDraft,
        loaded: [ConnectionSecretItem: String]?
    ) -> [ConnectionSecretItem: String]? {
        let values: [ConnectionSecretItem: String] = [
            .password: saving.credentials.password,
            .sshPassword: saving.ssh.password,
            .sshKeyPassphrase: saving.ssh.keyPassphrase,
            .totpSecret: saving.ssh.totpSecret,
            .sslClientKeyPassphrase: saving.ssl.clientKeyPassphrase,
        ].filter { !$0.value.isEmpty }
        guard loaded != nil || !values.isEmpty else { return nil }
        return values
    }

    private func finishTeamPublish(_ outcome: TeamLibraryPublishOutcome) {
        isPublishingTeamCopy = false
        switch outcome {
        case .failed(let error):
            saveError = .teamPublish(TeamLibraryPublishing.message(for: error).text)
        case .declined:
            return
        case .finished:
            baseline = draft
            dirtyBaseline = dirtyFingerprint()
            hasUnsavedChanges = false
            isClosing = true
            dismissAction?()
            TeamLibraryPublishing.present(outcome) {
                WelcomeRouter.shared.route(.resolveTeamLibraryConflicts)
            }
        }
    }
}
