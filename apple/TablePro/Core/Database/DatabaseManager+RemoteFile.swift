//
//  DatabaseManager+RemoteFile.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSSHConfig

extension DatabaseManager {
    /// Rewrites a file-backed connection to open a local working copy of a file that lives on an
    /// SSH server.
    ///
    /// The symmetry with the tunnel arm is the point: that one swaps `host` and `port` for the
    /// forwarded port and hands the driver a connection with no idea a tunnel exists, and this one
    /// swaps the path. A driver never learns its database came from somewhere else, which is what
    /// keeps every file-backed plugin working without changes.
    internal func buildRemoteFileEffectiveConnection(
        for connection: DatabaseConnection,
        sshPasswordOverride: String? = nil,
        deadline: ConnectionDeadline
    ) async throws -> DatabaseConnection {
        let sshConfig = connection.resolvedSSHConfig
        guard let field = pluginManager.localFilePathField(for: connection.type) else {
            throw ConnectionTunnelError.remoteFileUnsupported(connection.type.displayName)
        }

        let credentials = await sshCredentials(for: connection, passwordOverride: sshPasswordOverride)
        let identity = RemoteFileIdentity(
            username: sshConfig.username,
            host: sshConfig.host,
            port: sshConfig.port ?? 22,
            path: sshConfig.remoteFilePath
        )

        let file = try await RemoteFileTransportManager.shared.materialize(
            connectionId: connection.id,
            identity: identity,
            config: sshConfig,
            credentials: credentials,
            layout: DatabaseFileLayout.forType(connection.type),
            forceRefetch: false,
            deadline: deadline
        )

        return connection.substitutingLocalFilePath(file.workingCopy.path, in: field)
    }

    /// Answers Test Connection without fetching the database.
    ///
    /// The button asks three things: does the server accept these credentials, is the file there,
    /// and can this account read it. All three are settled by opening the session and asking for the
    /// file's attributes. Routing the test through the ordinary connect path instead would download
    /// the whole database before the button could report anything, which on a large one is minutes
    /// of transfer to answer a question that took one round trip.
    internal func testRemoteDatabaseFile(
        _ connection: DatabaseConnection,
        sshPassword: String?,
        deadline: ConnectionDeadline
    ) async throws -> Bool {
        let sshConfig = connection.resolvedSSHConfig
        guard !sshConfig.remoteFilePath.isEmpty else { throw ConnectionTunnelError.remoteFilePathMissing }

        let credentials = await sshCredentials(for: connection, passwordOverride: sshPassword)
        let session = try await LibSSH2SFTPSession.open(
            config: sshConfig,
            credentials: credentials,
            label: "test-\(connection.id.uuidString)",
            deadline: deadline
        )
        defer { session.close() }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let path = try session.resolvedPath(sshConfig.remoteFilePath, deadline: deadline)
            try Task.checkCancellation()
            let stat = try session.stat(path, deadline: deadline)
            try Task.checkCancellation()
            guard !stat.isDirectory else { throw SFTPError.notAFile(path: path) }
            return true
        } onCancel: {
            session.interruptCurrentOperation()
        }
    }

    internal func materializedRemoteFile(for connectionId: UUID) async -> MaterializedRemoteFile? {
        await RemoteFileTransportManager.shared.existingFile(for: connectionId)
    }

    // Reads off the main actor, since SecItemCopyMatching blocks its thread, and only the secrets the sign-in
    // can use, so an agent or key connection never touches the password's Keychain item.
    internal func sshCredentials(
        for connection: DatabaseConnection,
        passwordOverride: String?
    ) async -> SSHTunnelCredentials {
        let sshConfig = connection.resolvedSSHConfig
        let needs = SSHStoredSecretNeeds(
            authMethod: sshConfig.authMethod,
            totpMode: sshConfig.totpMode,
            passwordGiven: passwordOverride != nil
        )
        let password: DeferredSecretRead?
        let keyPassphrase: DeferredSecretRead?
        let totpSecret: DeferredSecretRead?

        switch connection.sshTunnelMode {
        case .disabled:
            password = nil
            keyPassphrase = nil
            totpSecret = nil
        case .profile(let profileId, _):
            let profiles = SSHProfileStorage.shared
            password = needs.password ? profiles.secretRead(.password, for: profileId) : nil
            keyPassphrase = needs.keyPassphrase ? profiles.secretRead(.keyPassphrase, for: profileId) : nil
            totpSecret = needs.totpSecret ? profiles.secretRead(.totpSecret, for: profileId) : nil
        case .inline:
            password = needs.password ? connectionStorage.sshPasswordRead(for: connection.id) : nil
            keyPassphrase = needs.keyPassphrase ? connectionStorage.keyPassphraseRead(for: connection.id) : nil
            totpSecret = needs.totpSecret ? connectionStorage.totpSecretRead(for: connection.id) : nil
        }

        let found = await DeferredSecretRead.run([password, keyPassphrase, totpSecret].compactMap { $0 })
        return SSHTunnelCredentials(
            sshPassword: passwordOverride ?? password.flatMap { found[$0.key] },
            keyPassphrase: keyPassphrase.flatMap { found[$0.key] },
            totpSecret: totpSecret.flatMap { found[$0.key] },
            keyboardInteractivePromptProvider: nil
        )
    }
}

extension DatabaseConnection {
    /// Returns a copy whose driver will open `path`, written into whichever field this driver reads.
    ///
    /// SQLite and Beancount take the built-in `database`; DuckDB and libSQL keep their path in a
    /// plugin-declared additional field and leave `database` empty, which is why the field cannot
    /// be assumed.
    func substitutingLocalFilePath(_ path: String, in field: LocalFilePathField) -> DatabaseConnection {
        var copy = self
        switch field {
        case .database:
            copy.database = path
        case .additionalField(let id):
            copy.additionalFields[id] = path
        }
        return copy
    }

    /// The path the driver will open, read from wherever this driver keeps it.
    func localFilePath(in field: LocalFilePathField) -> String {
        switch field {
        case .database:
            return database
        case .additionalField(let id):
            return additionalFields[id] ?? ""
        }
    }
}
