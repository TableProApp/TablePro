//
//  DatabaseManager+RemoteFile.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

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
        sshPasswordOverride: String? = nil
    ) async throws -> DatabaseConnection {
        let sshConfig = connection.resolvedSSHConfig
        guard let field = pluginManager.localFilePathField(for: connection.type) else {
            throw ConnectionTunnelError.remoteFileUnsupported(connection.type.displayName)
        }

        let credentials = sshCredentials(for: connection, passwordOverride: sshPasswordOverride)
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
            forceRefetch: false
        )

        var effective = connection.substitutingLocalFilePath(file.workingCopy.path, in: field)

        // Read-only is enforced here rather than promised in the pane's copy. The driver opens a
        // copy on this Mac, so an edit would succeed locally, change nothing on the server, and be
        // discarded the next time the file is fetched. Routing it through the same `safeModeLevel`
        // the rest of the app already honours means the grid, the editor and the AI tools all
        // refuse the write for the same reason, instead of each having to learn about remote files.
        effective.safeModeLevel = .readOnly
        return effective
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
        sshPassword: String?
    ) async throws -> Bool {
        let sshConfig = connection.resolvedSSHConfig
        guard !sshConfig.remoteFilePath.isEmpty else { throw ConnectionTunnelError.remoteFilePathMissing }

        let session = try await LibSSH2SFTPSession.open(
            config: sshConfig,
            credentials: sshCredentials(for: connection, passwordOverride: sshPassword),
            label: "test-\(connection.id.uuidString)"
        )
        defer { session.close() }

        let path = try session.resolvedPath(sshConfig.remoteFilePath)
        let stat = try session.stat(path)
        guard !stat.isDirectory else { throw SFTPError.notAFile(path: path) }
        return true
    }

    internal func materializedRemoteFile(for connectionId: UUID) async -> MaterializedRemoteFile? {
        await RemoteFileTransportManager.shared.existingFile(for: connectionId)
    }

    internal func sshCredentials(
        for connection: DatabaseConnection,
        passwordOverride: String?
    ) -> SSHTunnelCredentials {
        let storedPassword: String?
        let keyPassphrase: String?
        let totpSecret: String?

        switch connection.sshTunnelMode {
        case .disabled:
            storedPassword = nil
            keyPassphrase = nil
            totpSecret = nil
        case .profile(let profileId, _):
            storedPassword = SSHProfileStorage.shared.loadSSHPassword(for: profileId)
            keyPassphrase = SSHProfileStorage.shared.loadKeyPassphrase(for: profileId)
            totpSecret = SSHProfileStorage.shared.loadTOTPSecret(for: profileId)
        case .inline:
            storedPassword = connectionStorage.loadSSHPassword(for: connection.id)
            keyPassphrase = connectionStorage.loadKeyPassphrase(for: connection.id)
            totpSecret = connectionStorage.loadTOTPSecret(for: connection.id)
        }

        return SSHTunnelCredentials(
            sshPassword: passwordOverride ?? storedPassword,
            keyPassphrase: keyPassphrase,
            totpSecret: totpSecret,
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
