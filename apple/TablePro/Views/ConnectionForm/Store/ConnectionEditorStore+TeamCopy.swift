//
//  ConnectionEditorStore+TeamCopy.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

// An owner's, admin's or editor's edit of a Team Library connection. The form shows the team's copy with what the
// team's envelopes opened to, and Save publishes the edit back to the team, never to this Mac's library.
internal struct TeamCopyTarget {
    let original: TeamLibraryConnection
    // Nil when the team's secrets could not be read.
    let secrets: [ConnectionSecretItem: String]?
    // The sign-in shown when the person chose Edit: Save publishes only under it.
    let destination: TeamLibraryDestination
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
        secrets.totpSecret = target.secrets?[.totpSecret]
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
        let since = baselineEdits
        let changed = changedTeamSecrets(of: saving)
        saveError = nil
        isPublishingTeamCopy = true
        let library = teamLibrary
        Task { [weak self] in
            guard let self else { return }
            // Onto the team's copy as it is now, so a field a teammate changed since the form opened stays theirs.
            let current = library.content.connection(rowID: target.original.connection.id) ?? target.original
            let record = enforcingInvariants(edits.applied(to: current.connection, since: since)).record
            let outcome: TeamLibraryPublishOutcome
            switch await teamSecrets(for: record, current: current, changed: changed, library: library) {
            case .unreadable:
                outcome = .failed(.failed(.unavailable))
            case .secrets(let secrets):
                do throws(TeamLibraryPublishError) {
                    outcome = .finished(try await library.publishConnectionEdit(
                        record, of: target.original, secrets: secrets, to: target.destination
                    ))
                } catch {
                    outcome = .failed(error)
                }
            }
            finishTeamPublish(outcome, published: saving)
        }
        return .failure(.teamPublishInFlight)
    }

    // What the person changed of the secrets a team envelope carries; an emptied field removes that secret.
    func changedTeamSecrets(of saving: ConnectionDraft) -> [ConnectionSecretItem: String] {
        var changed: [ConnectionSecretItem: String] = [:]
        if saving.credentials.password != baseline.credentials.password {
            changed[.password] = saving.credentials.password
        }
        if saving.ssh.password != baseline.ssh.password {
            changed[.sshPassword] = saving.ssh.password
        }
        if saving.ssh.totpSecret != baseline.ssh.totpSecret {
            changed[.totpSecret] = saving.ssh.totpSecret
        }
        return changed
    }

    enum TeamCopySecrets {
        // Nil keeps the team's envelopes as they are.
        case secrets([ConnectionSecretItem: String]?)
        // A secret changed or the connection moved, and the team's secrets could not be read to carry the rest.
        case unreadable
    }

    // Nil while nothing secret changed and the connection still goes where the team's secrets were sealed for. Else
    // the whole set: the team's secrets as they are now with the person's changes, and a linked profile's in place of
    // the form's, since the copy goes out with that profile's values. A key file's passphrase stays on this Mac.
    func teamSecrets(
        for record: DatabaseConnection,
        current: TeamLibraryConnection,
        changed: [ConnectionSecretItem: String],
        library: TeamLibrary
    ) async -> TeamCopySecrets {
        let was = current.connection
        let moved = record.destination != was.destination
            || record.username != was.username
            || record.sshProfileId != was.sshProfileId
            || record.credentialMode != was.credentialMode
        guard moved || !changed.isEmpty else { return .secrets(nil) }
        guard var secrets = await library.secrets(for: current) else {
            return changed.isEmpty ? .secrets(nil) : .unreadable
        }
        for (item, value) in changed {
            secrets[item] = value.isEmpty ? nil : value
        }
        if case .profile(let profileId, _) = record.sshTunnelMode {
            secrets[.sshPassword] = services.sshProfileStorage.loadSSHPassword(for: profileId)
            secrets[.totpSecret] = services.sshProfileStorage.loadTOTPSecret(for: profileId)
        }
        if let profileId = record.credentialMode.profileId {
            secrets[.password] = services.credentialProfileStorage.loadPassword(for: profileId)
        }
        return .secrets(secrets.filter { !$0.value.isEmpty })
    }

    // Edits typed while the publish ran were not in it, so the window stays with them unsaved.
    private func finishTeamPublish(_ outcome: TeamLibraryPublishOutcome, published: ConnectionDraft) {
        isPublishingTeamCopy = false
        switch outcome {
        case .failed(let error):
            saveError = .teamPublish(TeamLibraryPublishing.message(for: error).text)
        case .declined:
            return
        case .finished:
            if ConnectionEditorEngine.normalized(draft, traits) == published {
                hasUnsavedChanges = false
                isClosing = true
                dismissAction?()
            }
            TeamLibraryPublishing.present(outcome) {
                WelcomeRouter.shared.route(.resolveTeamLibraryConflicts)
            }
        }
    }
}
