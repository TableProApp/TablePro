//
//  RemoteFileTransportManager.swift
//  TablePro
//

import Foundation
import os

/// What a connection's working copy is, once it has one.
struct MaterializedRemoteFile: Sendable {
    let identity: RemoteFileIdentity
    let workingCopy: URL
    let manifest: RemoteFileManifest
    let plan: RemoteFetchPlan
}

internal enum RemoteFileSessionOwnership {
    static func takeCurrent<Session: AnyObject>(
        _ current: inout Session?,
        ifOwnedBy expected: Session
    ) -> Session? {
        guard current === expected else { return nil }
        defer { current = nil }
        return current
    }

    static func takeCurrentGeneration(
        _ current: inout UUID?,
        ifCurrent expected: UUID
    ) -> Bool {
        guard current == expected else { return false }
        current = nil
        return true
    }

    /// Installs a new whole-materialization generation and atomically takes the old cached session
    /// when it supersedes work. The caller retires that session before the replacement can
    /// capture it. Otherwise both attempts can hold the same object and an old attempt's identity-
    /// guarded cleanup would still be able to close the winner's session.
    static func replaceCurrentGeneration<Session: AnyObject>(
        _ current: inout UUID?,
        with replacement: UUID,
        retiring currentSession: inout Session?
    ) -> (superseded: Bool, retiredSession: Session?) {
        let replacedExisting = current != nil
        current = replacement
        guard replacedExisting else { return (false, nil) }
        defer { currentSession = nil }
        return (true, currentSession)
    }
}

/// Owns the working copies of remote database files, one per connection.
///
/// A sibling of `SSHTunnelManager` and conforming to the same `TunnelManaging`, so disconnect,
/// health monitoring and the mutual-exclusivity check reach it the way they reach every other
/// transport. A transport with no case in `DatabaseManager.activeTunnelManager` is a transport
/// nothing can tear down.
///
/// The one behaviour that differs from a tunnel: rebuilding is not free. `SSHTunnelManager` throws
/// away its tunnel and dials again on every `createTunnel`, which costs a handshake. Doing that
/// here would re-download the database, so a reconnect reuses the copy already on disk. The health
/// monitor reconnects on a failed 30-second ping, so without this a network blip would pull a
/// multi-gigabyte file again, unattended, over the user's unsaved edits.
actor RemoteFileTransportManager: TunnelManaging {
    static let shared = RemoteFileTransportManager()

    private static let logger = Logger(subsystem: "com.TablePro", category: "RemoteDatabaseFile")

    private var materialized: [UUID: MaterializedRemoteFile] = [:]
    private var materializationRequestIds: [UUID: UUID] = [:]
    private var sessions: [UUID: LibSSH2SFTPSession] = [:]
    private var sessionRequestIds: [UUID: UUID] = [:]

    /// The server a cached session was opened against, so a session is not reused after the
    /// connection is edited to point at a different host, port, user or key. The path and the
    /// access mode are cleared first, because they name the file, not the server, and a live session
    /// to the right server serves any file on it.
    private var sessionServerKeys: [UUID: SSHConfiguration] = [:]

    // MARK: - TunnelManaging

    func hasTunnel(connectionId: UUID) async -> Bool {
        materialized[connectionId] != nil
    }

    /// Releases the connection's SFTP session and forgets the working copy, without deleting it.
    ///
    /// The file stays because it may hold edits the user has not written back. Deleting it here
    /// would make a disconnect the moment their work disappears, which is why
    /// `RemoteDatabaseFileStore.abandonedCopies()` exists to find it again.
    func closeTunnel(connectionId: UUID) async throws {
        materializationRequestIds.removeValue(forKey: connectionId)
        discardSession(for: connectionId)
        if let file = materialized.removeValue(forKey: connectionId) {
            Self.logger.info(
                "Released the working copy for \(file.identity.displayOrigin, privacy: .public)"
            )
        }
    }

    // MARK: - Materializing

    func existingFile(for connectionId: UUID) -> MaterializedRemoteFile? {
        materialized[connectionId]
    }

    /// Returns the local path the driver should open, fetching the file if this connection has not
    /// already got it.
    ///
    /// `forceRefetch` is what an explicit Download Again does. Every other caller, including every
    /// reconnect, gets the copy that is already there.
    func materialize(
        connectionId: UUID,
        identity: RemoteFileIdentity,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        layout: DatabaseFileLayout,
        forceRefetch: Bool,
        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
        deadline: ConnectionDeadline = ConnectionDeadline(configuredSeconds: nil)
    ) async throws -> MaterializedRemoteFile {
        let timeoutEndpoint = ConnectionTimeoutEndpoint.remoteFile("\(config.host):\(config.port ?? 22)")
        try Task.checkCancellation()
        try deadline.check(endpoint: timeoutEndpoint)
        if !forceRefetch, let existing = materialized[connectionId], existing.identity == identity {
            Self.logger.info(
                "Reusing the working copy for \(identity.displayOrigin, privacy: .public)"
            )
            return existing
        }

        let store = RemoteDatabaseFileStore.shared

        // The lock and the storage directory both key off the path the SERVER resolves, not the one
        // the user typed. Two connections naming `~/app.db` and `/home/deploy/app.db` are the same
        // file, and locking on the raw text lets them write one directory concurrently.
        let materializationRequestId = UUID()
        let replacement = RemoteFileSessionOwnership.replaceCurrentGeneration(
            &materializationRequestIds[connectionId],
            with: materializationRequestId,
            retiring: &sessions[connectionId]
        )
        if replacement.superseded {
            // A replacement must never share the old attempt's cached session. The old task keeps
            // its own reference for safe loser cleanup; removing and closing the cache here means
            // the replacement opens a different object, so the late loser cannot close the winner.
            sessionRequestIds.removeValue(forKey: connectionId)
            sessionServerKeys.removeValue(forKey: connectionId)
            replacement.retiredSession?.close()
        }
        let session: LibSSH2SFTPSession
        do {
            session = try await self.session(
                for: connectionId,
                config: config,
                credentials: credentials,
                deadline: deadline
            )
        } catch {
            finishMaterialization(connectionId: connectionId, requestId: materializationRequestId)
            throw error
        }
        do {
            try ensureMaterializationIsCurrent(
                connectionId: connectionId,
                requestId: materializationRequestId
            )
        } catch {
            discardSession(for: connectionId, ifOwnedBy: session)
            finishMaterialization(connectionId: connectionId, requestId: materializationRequestId)
            throw error
        }
        let cancelFlag = CancellationFlag()

        /// Any failure after the session is cached discards it, not only a failed transfer. A stat, a
        /// realpath, or a manifest write that throws leaves a session that is dead (the peer dropped)
        /// or pointed at a file that is gone, and reusing it makes every retry fail the same way
        /// until relaunch. This is the discard the fetch path used to make alone.
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let resolvedIdentity = try Self.resolvingHome(
                    identity,
                    on: session,
                    deadline: deadline
                )
                try Task.checkCancellation()
                let fileName = Self.workingCopyName(for: resolvedIdentity)

                return try await store.withExclusiveAccess(to: resolvedIdentity, deadline: deadline) {
                    try Task.checkCancellation()
                    try deadline.check(endpoint: timeoutEndpoint)
                    if !forceRefetch,
                       let reused = try await self.reusableCopy(
                           for: resolvedIdentity,
                           fileName: fileName,
                           session: session,
                           store: store,
                           deadline: deadline
                       ) {
                        try Task.checkCancellation()
                        try deadline.check(endpoint: timeoutEndpoint)
                        try await self.remember(
                            reused,
                            for: connectionId,
                            requestId: materializationRequestId
                        )
                        return reused
                    }

                    let directory = try await store.prepareDirectory(for: resolvedIdentity)
                    try Task.checkCancellation()
                    try deadline.check(endpoint: timeoutEndpoint)

                    let plan = try RemoteDatabaseFileTransfer.plan(
                        session: session,
                        remotePath: resolvedIdentity.path,
                        layout: layout,
                        deadline: deadline
                    )
                    try Task.checkCancellation()

                    let result = try RemoteDatabaseFileTransfer.fetch(
                        session: session,
                        identity: resolvedIdentity,
                        plan: plan,
                        layout: layout,
                        destinationDirectory: directory,
                        fileName: fileName,
                        deadline: deadline,
                        progress: progress,
                        isCancelled: { cancelFlag.isCancelled }
                    )
                    try Task.checkCancellation()
                    try deadline.check(endpoint: timeoutEndpoint)
                    try await store.writeManifest(result.manifest, for: resolvedIdentity)
                    try Task.checkCancellation()
                    try deadline.check(endpoint: timeoutEndpoint)

                    let file = MaterializedRemoteFile(
                        identity: resolvedIdentity,
                        workingCopy: result.workingCopy,
                        manifest: result.manifest,
                        plan: result.plan
                    )
                    try await self.remember(
                        file,
                        for: connectionId,
                        requestId: materializationRequestId
                    )
                    return file
                }
            } catch {
                await self.discardSession(for: connectionId, ifOwnedBy: session)
                await self.finishMaterialization(
                    connectionId: connectionId,
                    requestId: materializationRequestId
                )
                throw error
            }
        } onCancel: {
            cancelFlag.cancel()
            session.interruptCurrentOperation()
        }
    }

    // MARK: - Private

    private func remember(
        _ file: MaterializedRemoteFile,
        for connectionId: UUID,
        requestId: UUID
    ) throws {
        try ensureMaterializationIsCurrent(connectionId: connectionId, requestId: requestId)
        materialized[connectionId] = file
        materializationRequestIds.removeValue(forKey: connectionId)
    }

    private func ensureMaterializationIsCurrent(
        connectionId: UUID,
        requestId: UUID
    ) throws {
        try Task.checkCancellation()
        guard materializationRequestIds[connectionId] == requestId else {
            throw CancellationError()
        }
    }

    private func finishMaterialization(connectionId: UUID, requestId: UUID) {
        _ = RemoteFileSessionOwnership.takeCurrentGeneration(
            &materializationRequestIds[connectionId],
            ifCurrent: requestId
        )
    }

    /// A working copy already on disk that still matches the server, so the fetch can be skipped.
    ///
    /// The copy is read-only, so it can never differ from what was downloaded; the only question is
    /// whether the server has moved on. Comparing the recorded fingerprint against the file's
    /// current one answers that in a single round trip, which is the difference between a reconnect
    /// costing one `stat` and costing a multi-gigabyte download. The health monitor reconnects on a
    /// failed thirty-second ping, so this runs far more often than a user opens anything.
    private func reusableCopy(
        for identity: RemoteFileIdentity,
        fileName: String,
        session: LibSSH2SFTPSession,
        store: RemoteDatabaseFileStore,
        deadline: ConnectionDeadline
    ) async throws -> MaterializedRemoteFile? {
        guard let manifest = await store.manifest(for: identity) else { return nil }
        let workingCopy = await store.workingCopyURL(for: identity, fileName: fileName)
        guard FileManager.default.fileExists(atPath: workingCopy.path) else { return nil }

        let current = try RemoteDatabaseFileTransfer.fingerprint(
            session: session,
            remotePath: identity.path,
            deadline: deadline
        )
        guard !current.differs(from: manifest.fingerprint) else { return nil }

        Self.logger.info(
            "Reusing the working copy for \(identity.displayOrigin, privacy: .public): the server has not moved"
        )
        await store.touch(identity)
        return MaterializedRemoteFile(
            identity: identity,
            workingCopy: workingCopy,
            manifest: manifest,
            plan: .directCopy(sidecars: [])
        )
    }

    /// The working copy's file name, kept clear of the store's own metadata.
    ///
    /// A remote database literally called `manifest.json` would otherwise be written to the path the
    /// store writes its manifest to moments later, replacing the download with metadata before the
    /// driver ever opens it.
    private static func workingCopyName(for identity: RemoteFileIdentity) -> String {
        let base = (identity.path as NSString).lastPathComponent
        return base == RemoteDatabaseFileStore.manifestName ? "database-\(base)" : base
    }

    /// Drops a connection's cached SFTP session.
    ///
    /// A session is cached the moment authentication succeeds, so a later failure (the file is
    /// missing, the snapshot command failed, the transfer died) leaves a session behind that the
    /// next attempt reuses. After a network drop or a host edit that session is pointed at the old
    /// server, or dead, and every retry fails the same way until the app restarts.
    private func discardSession(for connectionId: UUID) {
        sessionRequestIds.removeValue(forKey: connectionId)
        sessions.removeValue(forKey: connectionId)?.close()
        sessionServerKeys.removeValue(forKey: connectionId)
    }

    private func discardSession(
        for connectionId: UUID,
        ifOwnedBy expected: LibSSH2SFTPSession
    ) {
        guard let session = RemoteFileSessionOwnership.takeCurrent(
            &sessions[connectionId],
            ifOwnedBy: expected
        ) else {
            expected.close()
            return
        }
        sessionServerKeys.removeValue(forKey: connectionId)
        session.close()
    }

    /// The session-identifying half of an SSH configuration: the server and its credentials, with the
    /// file path and access mode removed. Two configurations with the same key reach the same server
    /// and can share a session.
    static func serverKey(_ config: SSHConfiguration) -> SSHConfiguration {
        var key = config
        key.remoteFilePath = ""
        key.remoteFileAccess = .readOnlyCopy
        return key
    }

    private func session(
        for connectionId: UUID,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        deadline: ConnectionDeadline
    ) async throws -> LibSSH2SFTPSession {
        try deadline.check(endpoint: .remoteFile("\(config.host):\(config.port ?? 22)"))
        let key = Self.serverKey(config)
        if let existing = sessions[connectionId],
           sessionServerKeys[connectionId] == key,
           existing.canBeReused {
            return existing
        }
        discardSession(for: connectionId)
        let requestId = UUID()
        sessionRequestIds[connectionId] = requestId
        let opened: LibSSH2SFTPSession
        do {
            opened = try await LibSSH2SFTPSession.open(
                config: config,
                credentials: credentials,
                label: connectionId.uuidString,
                deadline: deadline
            )
        } catch {
            _ = RemoteFileSessionOwnership.takeCurrentGeneration(
                &sessionRequestIds[connectionId],
                ifCurrent: requestId
            )
            throw error
        }

        guard RemoteFileSessionOwnership.takeCurrentGeneration(
            &sessionRequestIds[connectionId],
            ifCurrent: requestId
        ) else {
            opened.close()
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
            try deadline.check(endpoint: .remoteFile("\(config.host):\(config.port ?? 22)"))
        } catch {
            opened.close()
            throw error
        }

        discardSession(for: connectionId)
        sessions[connectionId] = opened
        sessionServerKeys[connectionId] = key
        return opened
    }

    /// Turns whatever the user typed into the path the server sees.
    ///
    /// SFTP does no expansion: a literal `~/db.sqlite` fails to open, and a relative path is taken
    /// against the login directory. Both are things people type, so both are resolved through the
    /// server's own realpath rather than guessed at, and by the same code Test Connection uses so
    /// the button cannot succeed against a different file from the one that opens.
    private static func resolvingHome(
        _ identity: RemoteFileIdentity,
        on session: LibSSH2SFTPSession,
        deadline: ConnectionDeadline
    ) throws -> RemoteFileIdentity {
        let resolved = try session.resolvedPath(identity.path, deadline: deadline)
        guard resolved != identity.path else { return identity }
        return RemoteFileIdentity(
            username: identity.username,
            host: identity.host,
            port: identity.port,
            path: resolved
        )
    }
}
