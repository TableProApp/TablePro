//
//  RemoteDatabaseFileStore.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

/// Names the remote file a working copy belongs to.
///
/// The identity is the SSH account and the path, never the connection id. A connection can be
/// duplicated, edited to point somewhere else, or synced to another Mac, and in each case the id
/// says nothing about which bytes are on disk. Two connections naming the same file share one
/// working copy, which is what stops them writing over each other.
struct RemoteFileIdentity: Hashable, Sendable {
    let username: String
    let host: String
    let port: Int
    let path: String

    var displayOrigin: String {
        username.isEmpty ? "\(host):\(path)" : "\(username)@\(host):\(path)"
    }

    /// A stable directory name. Hashed rather than escaped because a remote path can be longer than
    /// a file name may be, and can hold any byte except NUL.
    var storageKey: String {
        let material = "\(username)\n\(host)\n\(port)\n\(path)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the app knows about a working copy without opening it.
///
/// Written beside the copy so a relaunch after a crash can still tell the user what they have and
/// where it came from. `downloadedSHA256` is the hash of the bytes that arrived, so a later
/// comparison can say whether the user changed anything without keeping a second copy.
struct RemoteFileManifest: Codable, Sendable, Equatable {
    let origin: String
    let username: String
    let host: String
    let port: Int
    let remotePath: String
    let fetchedAt: Date
    var remoteSize: UInt64
    var remoteModified: Date

    /// The log's size when the copy was taken, and nil when there was none.
    ///
    /// Kept because in WAL mode a commit lands here and leaves the main file's size and mtime
    /// untouched, so a baseline without it cannot tell an untouched database from a busy one.
    /// Dropping it also made the very first write-back compare a real size against nothing and
    /// report a conflict that was not there.
    var remoteWriteAheadLogSize: UInt64?

    /// The log's modification time when the copy was taken. Optional, so a manifest written before
    /// this field existed decodes with nil and the copy is refetched once to gain a full baseline.
    var remoteWriteAheadLogModified: Date?

    var downloadedSHA256: String
    let snapshotMethod: RemoteSnapshotMethod
    var fingerprint: RemoteFileFingerprint {
        RemoteFileFingerprint(
            mainSize: remoteSize,
            mainModified: remoteModified,
            writeAheadLogSize: remoteWriteAheadLogSize,
            writeAheadLogModified: remoteWriteAheadLogModified
        )
    }

    var identity: RemoteFileIdentity {
        RemoteFileIdentity(username: username, host: host, port: port, path: remotePath)
    }
}

/// How a working copy was taken, which decides how much the app may promise about it.
enum RemoteSnapshotMethod: String, Codable, Sendable {
    /// The server ran `VACUUM INTO`, which SQLite documents as safe while other processes write.
    case remoteSnapshot

    /// The bytes were copied straight off the server along with any sidecar carrying committed
    /// data. Correct when nothing else is writing, and not otherwise.
    case directCopy

    var isConsistentUnderConcurrentWriters: Bool { self == .remoteSnapshot }
}

struct RemoteFileGeneration: Sendable, Equatable {
    let identifier: UUID
    let identityDirectory: URL
    let directory: URL
    let workingCopy: URL

    var manifestURL: URL {
        directory.appendingPathComponent(RemoteDatabaseFileStore.manifestName)
    }
}

struct PublishedRemoteFileGeneration: Sendable {
    let generation: RemoteFileGeneration?
    let workingCopy: URL
    let manifest: RemoteFileManifest
}

private struct RemoteFileGenerationSelector: Codable {
    let formatVersion: Int
    let generationIdentifier: UUID
    let fileName: String
    let requiredSidecars: [String]
    let manifest: RemoteFileManifest
}

/// Owns the local copies of remote database files.
///
/// They live under Application Support rather than Caches, so a copy survives the system deciding
/// to reclaim space and a large database is not re-fetched for that reason alone.
/// `.swiftlint.yml` blocks resolving the Application Support directory anywhere but
/// `AppStorageEnvironment`, and does not block `.cachesDirectory`, so the wrong choice here would
/// have passed every check.
actor RemoteDatabaseFileStore {
    private enum WaiterFailure: Sendable {
        case cancelled
        case timedOut(ConnectionTimeoutError)
    }

    private struct Waiter {
        let ticket: UUID
        let continuation: CheckedContinuation<Void, Error>
        let deadlineTask: Task<Void, Never>?
    }

    static let shared = RemoteDatabaseFileStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "RemoteDatabaseFile")
    static let manifestName = "manifest.json"
    private static let generationPrefix = ".tablepro-generation-"
    private static let allowedSidecars = Set(
        DatabaseFileLayout.sqliteFamily.dataCarryingSidecarSuffixes
            + DatabaseFileLayout.duckdb.dataCarryingSidecarSuffixes
    )

    private var owners: [RemoteFileIdentity: UUID] = [:]
    private var waiters: [RemoteFileIdentity: [Waiter]] = [:]
    private var cleanedGenerationIdentities: Set<RemoteFileIdentity> = []
    private let rootOverride: URL?

    init(root: URL? = nil) {
        rootOverride = root
    }

    private var root: URL {
        if let rootOverride { return rootOverride }
        return AppStorageEnvironment.shared.supportDirectory
            .appendingPathComponent("RemoteDatabaseFiles", isDirectory: true)
    }

    func directory(for identity: RemoteFileIdentity) -> URL {
        root.appendingPathComponent(identity.storageKey, isDirectory: true)
    }

    func prepareDirectory(for identity: RemoteFileIdentity) throws -> URL {
        let directory = directory(for: identity)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Manifest

    func publishedGeneration(
        for identity: RemoteFileIdentity,
        fileName: String
    ) -> PublishedRemoteFileGeneration? {
        Self.publishedGeneration(in: directory(for: identity), fileName: fileName)
    }

    static func prepareGeneration(in identityDirectory: URL, fileName: String) throws -> RemoteFileGeneration {
        try FileManager.default.createDirectory(at: identityDirectory, withIntermediateDirectories: true)
        while true {
            let identifier = UUID()
            let generationDirectory = identityDirectory.appendingPathComponent(
                generationPrefix + identifier.uuidString,
                isDirectory: true
            )
            guard !FileManager.default.fileExists(atPath: generationDirectory.path) else { continue }
            do {
                try FileManager.default.createDirectory(
                    at: generationDirectory,
                    withIntermediateDirectories: false
                )
                return RemoteFileGeneration(
                    identifier: identifier,
                    identityDirectory: identityDirectory,
                    directory: generationDirectory,
                    workingCopy: generationDirectory.appendingPathComponent(fileName)
                )
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
    }

    static func writeManifest(_ manifest: RemoteFileManifest, to directory: URL) throws {
        let data = try JSONEncoder.remoteFileEncoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    /// `replaceReference` substitutes only the final atomic rename so tests can prove a failed
    /// publication leaves the prior selector intact.
    static func publish(
        _ generation: RemoteFileGeneration,
        requiredSidecars: Set<String>,
        replaceReference: ((URL, URL) throws -> Void)? = nil,
        didPublish: () -> Void = {}
    ) throws {
        let expectedDirectory = generation.identityDirectory
            .appendingPathComponent(generationPrefix + generation.identifier.uuidString, isDirectory: true)
        let fileName = generation.workingCopy.lastPathComponent
        guard generation.directory.standardizedFileURL == expectedDirectory.standardizedFileURL,
              generation.workingCopy.deletingLastPathComponent().standardizedFileURL
                  == generation.directory.standardizedFileURL,
              isSafeFileName(fileName),
              requiredSidecars.isSubset(of: allowedSidecars) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let requiredFiles = [generation.workingCopy]
            + requiredSidecars.map { URL(fileURLWithPath: generation.workingCopy.path + $0) }
        guard requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let manifestData = try Data(contentsOf: generation.manifestURL)
        let manifest = try JSONDecoder.remoteFileDecoder.decode(RemoteFileManifest.self, from: manifestData)
        let selector = RemoteFileGenerationSelector(
            formatVersion: 1,
            generationIdentifier: generation.identifier,
            fileName: fileName,
            requiredSidecars: requiredSidecars.sorted(),
            manifest: manifest
        )
        let selectorData = try JSONEncoder.remoteFileEncoder.encode(selector)

        let activeReference = generation.identityDirectory.appendingPathComponent(manifestName)
        let stagedReference = generation.identityDirectory.appendingPathComponent(
            ".\(manifestName)-\(UUID().uuidString).incoming"
        )
        defer { try? FileManager.default.removeItem(at: stagedReference) }
        try selectorData.write(to: stagedReference, options: .withoutOverwriting)
        if let replaceReference {
            try replaceReference(stagedReference, activeReference)
        } else {
            try replace(stagedReference, with: activeReference)
        }
        didPublish()
    }

    static func discardUnpublishedGeneration(_ generation: RemoteFileGeneration) {
        let selected = readSelector(
            at: generation.identityDirectory.appendingPathComponent(manifestName)
        )?.generationIdentifier
        guard selected != generation.identifier else { return }
        try? FileManager.default.removeItem(at: generation.directory)
    }

    static func publishedGeneration(
        in identityDirectory: URL,
        fileName: String
    ) -> PublishedRemoteFileGeneration? {
        let manifestURL = identityDirectory.appendingPathComponent(manifestName)
        guard let manifestData = try? Data(contentsOf: manifestURL) else { return nil }
        if let selector = try? JSONDecoder.remoteFileDecoder.decode(
            RemoteFileGenerationSelector.self,
            from: manifestData
        ) {
            guard selector.formatVersion == 1,
                  selector.fileName == fileName,
                  isSafeFileName(selector.fileName) else { return nil }
            let requiredSidecars = Set(selector.requiredSidecars)
            guard requiredSidecars.count == selector.requiredSidecars.count,
                  requiredSidecars.isSubset(of: allowedSidecars) else { return nil }
            let directory = identityDirectory.appendingPathComponent(
                generationPrefix + selector.generationIdentifier.uuidString,
                isDirectory: true
            )
            let generation = RemoteFileGeneration(
                identifier: selector.generationIdentifier,
                identityDirectory: identityDirectory,
                directory: directory,
                workingCopy: directory.appendingPathComponent(selector.fileName)
            )
            let requiredFiles = [generation.workingCopy, generation.manifestURL]
                + requiredSidecars.map { URL(fileURLWithPath: generation.workingCopy.path + $0) }
            guard requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }),
                  readManifest(at: generation.manifestURL) == selector.manifest else { return nil }
            return PublishedRemoteFileGeneration(
                generation: generation,
                workingCopy: generation.workingCopy,
                manifest: selector.manifest
            )
        }

        guard let manifest = try? JSONDecoder.remoteFileDecoder.decode(
            RemoteFileManifest.self,
            from: manifestData
        ) else { return nil }
        let legacyWorkingCopy = identityDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: legacyWorkingCopy.path) else { return nil }
        return PublishedRemoteFileGeneration(
            generation: nil,
            workingCopy: legacyWorkingCopy,
            manifest: manifest
        )
    }

    private static func readManifest(at url: URL) -> RemoteFileManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.remoteFileDecoder.decode(RemoteFileManifest.self, from: data)
    }

    private static func readSelector(at url: URL) -> RemoteFileGenerationSelector? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.remoteFileDecoder.decode(RemoteFileGenerationSelector.self, from: data)
    }

    private static func isSafeFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && fileName != "."
            && fileName != ".."
            && !fileName.contains("/")
    }

    private static func replace(_ source: URL, with destination: URL) throws {
        let failure = source.withUnsafeFileSystemRepresentation { sourcePath -> POSIXErrorCode? in
            destination.withUnsafeFileSystemRepresentation { destinationPath -> POSIXErrorCode? in
                guard let sourcePath, let destinationPath else { return .ENOENT }
                guard rename(sourcePath, destinationPath) != 0 else { return nil }
                return POSIXErrorCode(rawValue: errno) ?? .EIO
            }
        }
        if let failure {
            throw POSIXError(failure)
        }
    }

    // MARK: - Exclusion

    /// Serializes every fetch and write-back that names one remote file, across every window and
    /// every connection in this process.
    ///
    /// Two connections can name the same file, and nothing stops a user opening both. Without this
    /// their uploads interleave and either one can replace the other's temp file before the rename
    /// promotes it. `SSHTunnelManager` fences by connection id for the same reason; the key here is
    /// the file, because the file is what is shared.
    func withExclusiveAccess<T: Sendable>(
        to identity: RemoteFileIdentity,
        deadline: ConnectionDeadline? = nil,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let ticket = try await acquire(identity, deadline: deadline)
        defer { release(identity, ticket: ticket) }
        if cleanedGenerationIdentities.insert(identity).inserted {
            Self.pruneInactiveGenerations(in: directory(for: identity))
        }

        return try await operation()
    }

    #if DEBUG
    internal func waiterCount(for identity: RemoteFileIdentity) -> Int {
        waiters[identity]?.count ?? 0
    }
    #endif

    private func acquire(
        _ identity: RemoteFileIdentity,
        deadline: ConnectionDeadline?
    ) async throws -> UUID {
        try Task.checkCancellation()
        let timeoutEndpoint = ConnectionTimeoutEndpoint.remoteFile("\(identity.host):\(identity.port)")
        if let deadline {
            try deadline.check(endpoint: timeoutEndpoint)
        }
        let ticket = UUID()
        guard owners[identity] != nil else {
            owners[identity] = ticket
            return ticket
        }

        try await withTaskCancellationHandler(
            operation: {
                try await enqueue(
                    ticket: ticket,
                    identity: identity,
                    deadline: deadline,
                    timeoutEndpoint: timeoutEndpoint
                )
            },
            onCancel: {
                Task {
                    await self.failWaiter(
                        ticket: ticket,
                        identity: identity,
                        failure: .cancelled
                    )
                }
            }
        )

        guard owners[identity] == ticket else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
            if let deadline {
                try deadline.check(endpoint: timeoutEndpoint)
            }
        } catch {
            release(identity, ticket: ticket)
            throw error
        }
        return ticket
    }

    private func enqueue(
        ticket: UUID,
        identity: RemoteFileIdentity,
        deadline: ConnectionDeadline?,
        timeoutEndpoint: ConnectionTimeoutEndpoint
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            let deadlineTask = deadline.map { deadline in
                Task { [weak self] in
                    do {
                        try await ContinuousClock().sleep(until: deadline.instant)
                    } catch {
                        return
                    }
                    await self?.failWaiter(
                        ticket: ticket,
                        identity: identity,
                        failure: .timedOut(deadline.timeoutError(for: timeoutEndpoint))
                    )
                }
            }
            waiters[identity, default: []].append(
                Waiter(
                    ticket: ticket,
                    continuation: continuation,
                    deadlineTask: deadlineTask
                )
            )
        }
    }

    private func failWaiter(
        ticket: UUID,
        identity: RemoteFileIdentity,
        failure: WaiterFailure
    ) {
        guard var pending = waiters[identity],
              let index = pending.firstIndex(where: { $0.ticket == ticket })
        else {
            return
        }
        let waiter = pending.remove(at: index)
        waiters[identity] = pending.isEmpty ? nil : pending
        waiter.deadlineTask?.cancel()
        switch failure {
        case .cancelled:
            waiter.continuation.resume(throwing: CancellationError())
        case .timedOut(let error):
            waiter.continuation.resume(throwing: error)
        }
    }

    private func release(_ identity: RemoteFileIdentity, ticket: UUID) {
        guard owners[identity] == ticket else { return }
        guard var pending = waiters[identity], !pending.isEmpty else {
            owners.removeValue(forKey: identity)
            waiters.removeValue(forKey: identity)
            return
        }
        let next = pending.removeFirst()
        waiters[identity] = pending.isEmpty ? nil : pending
        next.deadlineTask?.cancel()
        owners[identity] = next.ticket
        next.continuation.resume()
    }

    // MARK: - Housekeeping

    func discard(_ identity: RemoteFileIdentity) {
        try? FileManager.default.removeItem(at: directory(for: identity))
        Self.logger.info("Discarded the working copy for \(identity.displayOrigin, privacy: .public)")
    }

    /// Marks a copy as used, so a reuse counts against the abandonment clock the same as a fresh
    /// fetch. Reading a file does not move a directory's modification time, so reuse would otherwise
    /// leave a copy that is opened daily looking abandoned once the server stopped changing.
    func touch(_ identity: RemoteFileIdentity) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: directory(for: identity).path
        )
    }

    /// Removes working copies nothing has used within `maxAge`, which is how a copy left behind by a
    /// deleted connection or a changed path is eventually reclaimed. Nothing else deletes them:
    /// `discard` has no routine caller, because a copy keyed by the resolved server path cannot be
    /// found from a connection's unresolved one at delete time.
    ///
    /// Sweeping a copy is safe when no materialization owns it. A remote file connection is read-only
    /// and re-fetches on next open, so a removed copy costs one download and never loses data. The
    /// directory's modification time is the last-used mark, moved forward by a fresh fetch and by
    /// `touch` on every reuse.
    func pruneAbandoned(olderThan maxAge: TimeInterval = 30 * 24 * 60 * 60, now: Date = Date()) {
        let excludedStorageKeys = Set(owners.keys.map(\.storageKey))
        Self.pruneAbandoned(
            in: root,
            olderThan: maxAge,
            now: now,
            excludingStorageKeys: excludedStorageKeys
        )
    }

    /// The filesystem half of `pruneAbandoned`, taking its root explicitly so a test can point it at
    /// a temporary directory rather than the app's real store.
    static func pruneAbandoned(
        in root: URL,
        olderThan maxAge: TimeInterval,
        now: Date,
        excludingStorageKeys: Set<String> = []
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            guard !excludingStorageKeys.contains(url.lastPathComponent) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > maxAge else { continue }
            try? fileManager.removeItem(at: url)
            logger.info("Pruned a remote database working copy unused for over \(Int(maxAge / 86_400)) days")
        }
    }

    static func pruneInactiveGenerations(in identityDirectory: URL) {
        let activeIdentifier = readSelector(
            at: identityDirectory.appendingPathComponent(manifestName)
        )?.generationIdentifier
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: identityDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(generationPrefix),
                  let identifier = UUID(uuidString: String(name.dropFirst(generationPrefix.count))),
                  identifier != activeIdentifier else { continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                logger.error("Could not remove an inactive remote-file generation")
            }
        }
    }
}

private extension JSONEncoder {
    static var remoteFileEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var remoteFileDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
