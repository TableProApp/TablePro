//
//  ConnectionEditorStore+Load.swift
//  TablePro
//

import Combine
import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig
import TableProSSHTransport
import TableProUtilities

extension ConnectionEditorStore {
    func load(_ request: Request) {
        context = makeContext()
        switch request {
        case .new(_, let parsedURL):
            baseline = draft
            dirtyBaseline = dirtyFingerprint()
            if let parsedURL {
                var imported = draft
                imported.apply(parsedURL, traits: traits, policy: .newConnection)
                draft = ConnectionEditorEngine.normalized(imported, traits)
            }
        case .edit(let id):
            isLibraryUnreadable = storage.isLibraryUnreadable
            guard let record = storage.loadConnection(id: id) else {
                isRecordMissing = !isLibraryUnreadable
                baseline = draft
                refreshDerivedState()
                return
            }
            traits = ConnectionTypeTraits.live(for: record.type, pluginManager: services.pluginManager)
            originalTraits = traits
            context.originalType = record.type
            context.savedName = record.name
            context.participatesInSync = record.participatesInSync
            var secrets = DraftSecrets()
            let reads = storage.recordingSecretReads {
                secrets = readSecrets(of: record)
            }
            unreadableSecretKeys = reads.unreadable
            loadedSecrets = reads.loaded
            draft = ConnectionDraft.loaded(from: record, secrets: secrets, traits: traits)
            baseline = draft
            loadedRecord = record
            baselineEdits = ConnectionEditorEngine.edits(draft, traits, originalTraits: originalTraits, context)
            dirtyBaseline = dirtyFingerprint()
        }
        refreshDerivedState()
        loadSSHConfigEntries()
    }

    func readSecrets(of record: DatabaseConnection) -> DraftSecrets {
        let id = record.id
        var secrets = DraftSecrets()
        secrets.passwordState = storage.passwordState(for: id)
        secrets.password = storage.loadPassword(for: id)
        if case .profile(let profileId, _) = record.sshTunnelMode {
            // Shown so a switch to Inline Configuration carries them; the connection's own namespace stays as it is.
            let profiles = services.sshProfileStorage
            secrets.sshPassword = profiles.loadSSHPassword(for: profileId)
            secrets.sshKeyPassphrase = profiles.loadKeyPassphrase(for: profileId)
            secrets.totpSecret = profiles.loadTOTPSecret(for: profileId)
        } else {
            secrets.sshPasswordState = storage.sshPasswordState(for: id)
            secrets.sshKeyPassphraseState = storage.keyPassphraseState(for: id)
            secrets.sshPassword = storage.loadSSHPassword(for: id)
            secrets.sshKeyPassphrase = storage.loadKeyPassphrase(for: id)
            secrets.totpSecret = storage.loadTOTPSecret(for: id)
        }
        secrets.sslClientKeyPassphrase = storage.loadSSLClientKeyPassphrase(for: id)
        secrets.cloudflareTokenId = storage.loadCloudflareTokenId(for: id)
        secrets.cloudflareTokenSecret = storage.loadCloudflareTokenSecret(for: id)
        secrets.cloudSQLServiceAccountKey = storage.loadCloudSQLProxyServiceAccountKey(for: id)
        secrets.socksPassword = storage.loadSOCKSProxyPassword(for: id)
        for fieldId in traits.declaredSecureFieldIds {
            var value: String?
            let reads = storage.recordingSecretReads {
                value = storage.loadPluginSecureField(fieldId: fieldId, for: id)
            }
            // A stored item wins over a plain-text copy an unfinished Keychain migration left, as the migration rules.
            if (value ?? "").isEmpty, reads.unreadable.isEmpty,
               let plaintext = record.additionalFields[fieldId], !plaintext.isEmpty {
                secrets.pluginSecureFields[fieldId] = plaintext
            } else if let value {
                secrets.pluginSecureFields[fieldId] = value
            }
        }
        return secrets
    }

    func makeContext() -> EditorContext {
        var context = EditorContext()
        context.isNew = isNew
        context.originalType = self.context.originalType
        context.savedName = self.context.savedName
        context.participatesInSync = self.context.participatesInSync
        context.aiEnabled = services.appSettings.ai.enabled
        context.syncEnabled = services.appSettings.sync.enabled
        context.managedSafeModeMinimum = ManagedPolicyResolver.minimumSafeModeLevel(policy: managedPolicy)
        let credentialStorage = services.credentialProfileStorage
        context.credentialProfiles = credentialStorage.loadProfiles()
        context.credentialProfilesLoadFailed = credentialStorage.lastLoadFailed
        let sshStorage = services.sshProfileStorage
        context.sshProfiles = sshStorage.loadProfiles()
        context.sshProfilesLoadFailed = sshStorage.lastLoadFailed
        context.sshConfigEntries = self.context.sshConfigEntries
        return context
    }

    func refreshContext() {
        context = makeContext()
        refreshDerivedState()
    }

    // The config parse runs off the main thread; the matching host is picked once the entries arrive.
    func loadSSHConfigEntries() {
        Task { [weak self] in
            let entries = await Task.detached { SSHConfigParser.parse() }.value
            guard let self, !self.isClosing else { return }
            self.context.sshConfigEntries = entries
            if self.draft.ssh.selectedConfigHost.isEmpty, let match = entries.first(where: { $0.host == self.draft.ssh.host }) {
                var next = self.draft
                next.ssh.selectedConfigHost = match.host
                self.baseline.ssh.selectedConfigHost = match.host
                self.commit(next)
            } else {
                self.refreshDerivedState()
            }
        }
    }

    // MARK: - Listeners

    // Owned here, not by a view: a facet that is not on screen still needs every one of these.
    func subscribe() {
        NotificationCenter.default.publisher(for: .credentialProfilesDidChange)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.credentialProfilesDidChange() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .sshProfilesDidChange)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.sshProfilesDidChange() }
            }
            .store(in: &cancellables)
        services.appEvents.connectionUpdated
            .sink { [weak self] id in
                MainActor.assumeIsolated { self?.connectionDidUpdate(id) }
            }
            .store(in: &cancellables)
        cloudSQLProxyDownload.$phase
            .sink { [weak self] phase in
                MainActor.assumeIsolated { self?.cloudSQLProxyDownloadDidChange(phase) }
            }
            .store(in: &cancellables)
        services.appSettings.$ai.map(\.enabled).removeDuplicates()
            .combineLatest(services.appSettings.$sync.map(\.enabled).removeDuplicates())
            .dropFirst()
            .sink { [weak self] aiEnabled, syncEnabled in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.context.aiEnabled = aiEnabled
                    self.context.syncEnabled = syncEnabled
                    self.refreshDerivedState()
                }
            }
            .store(in: &cancellables)
    }

    // Storage has already handed a dead profile's credentials to the connection inline, so keeping the id would undo that.
    func credentialProfilesDidChange() {
        refreshContext()
        guard !context.credentialProfilesLoadFailed,
              let profileId = draft.credentials.mode.profileId,
              context.credentialProfile(profileId) == nil
        else { return }
        var next = draft
        next.credentials.mode = .inline
        if !isNew, let refreshed = storage.loadConnection(id: connectionId) {
            let reads = storage.recordingSecretReads {
                next.credentials.username = refreshed.username
                next.credentials.promptsForPassword = refreshed.promptForPassword
                next.credentials.passwordSource = refreshed.passwordSource
                next.credentials.storedPasswordState = storage.passwordState(for: refreshed.id)
                next.credentials.password = storage.loadPassword(for: refreshed.id) ?? ""
            }
            if traits.field(ConnectionEditorEngine.pgpassFieldId) != nil {
                next.fieldValues[ConnectionEditorEngine.pgpassFieldId] = refreshed.usePgpass ? "true" : "false"
            }
            unreadableSecretKeys.formUnion(reads.unreadable)
            loadedSecrets.merge(reads.loaded) { _, fresh in fresh }
            // Test builds on the loaded record, and the edits never carry the source, so it takes the same hand-over.
            loadedRecord?.takeSignIn(from: refreshed)
        }
        commit(next)
    }

    // Storage turns a deleted profile's links inline with its secrets: adopt that. A profile never on this Mac stays linked.
    func sshProfilesDidChange() {
        refreshContext()
        guard !context.sshProfilesLoadFailed,
              let profileId = draft.ssh.profileId,
              context.sshProfile(profileId) == nil,
              !isNew,
              let refreshed = storage.loadConnection(id: connectionId),
              !refreshed.isLinked(toSSHProfile: profileId),
              case .inline(let config) = refreshed.sshTunnelMode
        else { return }
        var next = draft
        next.ssh.profileId = nil
        next.ssh.profileSnapshot = nil
        next.ssh.populateFields(from: config, configEntries: context.sshConfigEntries)
        let reads = storage.recordingSecretReads {
            next.ssh.storedPasswordState = storage.sshPasswordState(for: connectionId)
            next.ssh.storedKeyPassphraseState = storage.keyPassphraseState(for: connectionId)
            next.ssh.password = storage.loadSSHPassword(for: connectionId) ?? ""
            next.ssh.keyPassphrase = storage.loadKeyPassphrase(for: connectionId) ?? ""
            next.ssh.totpSecret = storage.loadTOTPSecret(for: connectionId) ?? ""
        }
        unreadableSecretKeys.formUnion(reads.unreadable)
        loadedSecrets.merge(reads.loaded) { _, fresh in fresh }
        commit(next)
    }

    // The baseline stays where load put it: moving it would make every untouched field look edited and revert the change.
    func connectionDidUpdate(_ id: UUID?) {
        guard !isClosing, !isNew, id == nil || id == connectionId else { return }
        if !storage.isLibraryUnreadable, storage.loadConnection(id: connectionId) == nil {
            isRecordMissing = true
            cancelTest()
        }
        refreshContext()
    }

    // MARK: - Detection

    // Runs when the transport is picked, for a new connection as much as a stored one.
    func startBinaryDetectionIfNeeded() {
        if draft.transport == .cloudflare, cloudflaredDetection == .notChecked {
            detectCloudflared()
        }
        if draft.transport == .cloudSQLProxy, cloudSQLProxyDetection == .notChecked {
            detectCloudSQLProxy()
        }
    }

    func detectCloudflared() {
        cloudflaredDetection = .checking
        Task { [weak self] in
            let path = await Task.detached { CLIExecutableFinder.findExecutable("cloudflared") }.value
            self?.cloudflaredDetection = path.map(BinaryDetection.found) ?? .notFound
        }
    }

    func detectCloudSQLProxy() {
        cloudSQLProxyDetection = .checking
        let binaryManager = cloudSQLProxyDownload.binaryManager
        Task { [weak self] in
            let found = await Task.detached { CLIExecutableFinder.findExecutable("cloud-sql-proxy") }.value
            var path = found
            if path == nil, await binaryManager.installedBinaryIsCurrent() {
                path = binaryManager.binaryExecutablePath
            }
            self?.cloudSQLProxyDetection = path.map(BinaryDetection.found) ?? .notFound
        }
    }

    // A connect or a Test can download the binary too, so this follows the shared download.
    func cloudSQLProxyDownloadDidChange(_ phase: CloudSQLProxyDownload.Phase) {
        cloudSQLProxyDownloadPhase = phase
        if phase == .idle, wasDownloadingCloudSQLProxy {
            detectCloudSQLProxy()
        }
        wasDownloadingCloudSQLProxy = phase.isDownloading
    }

    func downloadCloudSQLProxy() {
        cloudSQLProxyDownload.start()
    }

    func cancelCloudSQLProxyDownload() {
        cloudSQLProxyDownload.cancel()
    }

    // MARK: - pgpass

    func refreshPgpassStatus() {
        guard ConnectionEditorEngine.usesPgpass(draft, traits) else {
            pgpassLookup = nil
            if pgpassStatus != .notChecked {
                pgpassStatus = .notChecked
            }
            return
        }
        let lookup = currentPgpassLookup()
        guard lookup != pgpassLookup else { return }
        pgpassLookup = lookup
        pgpassStatus = PgpassStatus.check(
            host: lookup.host,
            port: lookup.port,
            database: lookup.database,
            username: lookup.username
        )
    }

    private func currentPgpassLookup() -> PgpassLookup {
        let host: String
        let port: Int
        if traits.localSocketIsDirectory, let socket = ConnectionEditorEngine.localSocketEndpoint(draft, traits) {
            host = PostgreSQLLocalSocket.pgpassHost(forHost: socket.path)
            port = socket.port
        } else {
            host = PostgreSQLLocalSocket.pgpassHost(forHost: ConnectionEditorEngine.resolvedHost(draft, traits))
            port = ConnectionEditorEngine.resolvedPort(draft, traits)
        }
        return PgpassLookup(
            host: host,
            port: port,
            database: draft.database,
            username: PgpassReader.effectiveUsername(draft.credentials.username.trimmingCharacters(in: .whitespaces))
        )
    }
}

private extension DatabaseConnection {
    // What CredentialProfileStorage.unlinkConnections writes onto a connection whose profile is deleted.
    mutating func takeSignIn(from other: DatabaseConnection) {
        credentialMode = other.credentialMode
        username = other.username
        passwordSource = other.passwordSource
        for key in ["promptForPassword", ConnectionEditorEngine.pgpassFieldId] {
            additionalFields[key] = other.additionalFields[key]
        }
    }
}
