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
    private var sessions: [UUID: LibSSH2SFTPSession] = [:]

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
        sessions.removeValue(forKey: connectionId)?.close()
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
        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil
    ) async throws -> MaterializedRemoteFile {
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
        let session = try await self.session(for: connectionId, config: config, credentials: credentials)
        let resolvedIdentity = try Self.resolvingHome(identity, on: session)
        let fileName = Self.workingCopyName(for: resolvedIdentity)

        return try await store.withExclusiveAccess(to: resolvedIdentity) {
            if !forceRefetch,
               let reused = try await self.reusableCopy(
                   for: resolvedIdentity, fileName: fileName, session: session, store: store
               ) {
                await self.remember(reused, for: connectionId)
                return reused
            }

            let directory = try await store.prepareDirectory(for: resolvedIdentity)

            let plan = RemoteDatabaseFileTransfer.plan(
                session: session,
                remotePath: resolvedIdentity.path,
                layout: layout
            )

            let cancelFlag = CancellationFlag()
            let result: RemoteFetchResult
            do {
                result = try await withTaskCancellationHandler {
                    try RemoteDatabaseFileTransfer.fetch(
                        session: session,
                        identity: resolvedIdentity,
                        plan: plan,
                        layout: layout,
                        destinationDirectory: directory,
                        fileName: fileName,
                        progress: progress,
                        isCancelled: { cancelFlag.isCancelled }
                    )
                } onCancel: {
                    cancelFlag.cancel()
                }
            } catch {
                await self.discardSession(for: connectionId)
                throw error
            }
            try await store.writeManifest(result.manifest, for: resolvedIdentity)

            let file = MaterializedRemoteFile(
                identity: resolvedIdentity,
                workingCopy: result.workingCopy,
                manifest: result.manifest,
                plan: result.plan
            )
            await self.remember(file, for: connectionId)
            return file
        }
    }

    // MARK: - Private

    private func remember(_ file: MaterializedRemoteFile, for connectionId: UUID) {
        materialized[connectionId] = file
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
        store: RemoteDatabaseFileStore
    ) async throws -> MaterializedRemoteFile? {
        guard let manifest = await store.manifest(for: identity) else { return nil }
        let workingCopy = await store.workingCopyURL(for: identity, fileName: fileName)
        guard FileManager.default.fileExists(atPath: workingCopy.path) else { return nil }

        let current = try RemoteDatabaseFileTransfer.fingerprint(
            session: session, remotePath: identity.path
        )
        guard !current.differs(from: manifest.fingerprint) else { return nil }

        Self.logger.info(
            "Reusing the working copy for \(identity.displayOrigin, privacy: .public): the server has not moved"
        )
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
        sessions.removeValue(forKey: connectionId)?.close()
    }

    private func session(
        for connectionId: UUID,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials
    ) async throws -> LibSSH2SFTPSession {
        if let existing = sessions[connectionId] { return existing }
        let session = try await LibSSH2SFTPSession.open(
            config: config,
            credentials: credentials,
            label: connectionId.uuidString
        )
        sessions[connectionId] = session
        return session
    }

    /// Turns whatever the user typed into the path the server sees.
    ///
    /// SFTP does no expansion: a literal `~/db.sqlite` fails to open, and a relative path is taken
    /// against the login directory. Both are things people type, so both are resolved through the
    /// server's own realpath rather than guessed at, and by the same code Test Connection uses so
    /// the button cannot succeed against a different file from the one that opens.
    private static func resolvingHome(
        _ identity: RemoteFileIdentity,
        on session: LibSSH2SFTPSession
    ) throws -> RemoteFileIdentity {
        let resolved = try session.resolvedPath(identity.path)
        guard resolved != identity.path else { return identity }
        return RemoteFileIdentity(
            username: identity.username,
            host: identity.host,
            port: identity.port,
            path: resolved
        )
    }
}
