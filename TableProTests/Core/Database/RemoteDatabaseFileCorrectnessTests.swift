//
//  RemoteDatabaseFileCorrectnessTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct RemoteDatabaseFileCorrectnessTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Fingerprint

    @Test("A commit that moves only the write-ahead log's mtime is a change")
    func walModifiedIsAChange() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let recorded = RemoteFileFingerprint(
            mainSize: 32_768, mainModified: base, writeAheadLogSize: 234_872, writeAheadLogModified: base
        )
        let current = RemoteFileFingerprint(
            mainSize: 32_768, mainModified: base, writeAheadLogSize: 234_872, writeAheadLogModified: base.addingTimeInterval(5)
        )
        #expect(current.differs(from: recorded))
    }

    @Test("An identical fingerprint including the log mtime is not a change")
    func identicalWithLogMtimeIsNotAChange() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = RemoteFileFingerprint(mainSize: 4_096, mainModified: base, writeAheadLogSize: 100, writeAheadLogModified: base)
        let b = RemoteFileFingerprint(mainSize: 4_096, mainModified: base, writeAheadLogSize: 100, writeAheadLogModified: base)
        #expect(!a.differs(from: b))
    }

    // MARK: - Manifest codec

    @Test("A manifest written before the log mtime field decodes with nil")
    func manifestWithoutLogMtimeDecodesNil() throws {
        let json = Data("""
        {"origin":"u@h:/p","username":"u","host":"h","port":22,"remotePath":"/p",
         "fetchedAt":"2026-01-01T00:00:00Z","remoteSize":4096,"remoteModified":"2026-01-01T00:00:00Z",
         "downloadedSHA256":"abc","snapshotMethod":"directCopy"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RemoteFileManifest.self, from: json)
        #expect(manifest.remoteWriteAheadLogModified == nil)
        #expect(manifest.fingerprint.writeAheadLogModified == nil)
    }

    // MARK: - Generation publication

    @Test("A prepared generation stays invisible until its selector is published")
    func preparedGenerationIsInvisibleUntilPublication() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let old = try stagedResult(
            in: directory,
            identity: identity,
            main: Data("old main".utf8),
            sidecars: ["-wal": Data("old wal".utf8)],
            marker: "old"
        )
        _ = try publish(old, identity: identity)
        let new = try stagedResult(
            in: directory,
            identity: identity,
            main: Data("new main".utf8),
            sidecars: ["-journal": Data("new journal".utf8)],
            marker: "new"
        )

        let selected = try #require(RemoteDatabaseFileStore.publishedGeneration(
            in: directory,
            fileName: "app.db"
        ))
        #expect(selected.generation?.identifier == old.generation.identifier)
        #expect(try Data(contentsOf: selected.workingCopy) == Data("old main".utf8))
        #expect(FileManager.default.fileExists(atPath: new.generation.directory.path))

        RemoteDatabaseFileStore.discardUnpublishedGeneration(new.generation)
        #expect(!FileManager.default.fileExists(atPath: new.generation.directory.path))
    }

    @Test("Publishing exposes one coherent generation and preserves every older reader path")
    func publicationIsCoherentAndKeepsOldPathsImmutable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let old = try stagedResult(
            in: directory,
            identity: identity,
            main: Data("old main".utf8),
            sidecars: [
                "-wal": Data("old wal".utf8),
                "-journal": Data("old journal".utf8),
            ],
            marker: "old"
        )
        let oldFile = try publish(old, identity: identity)
        let openOldMain = try FileHandle(forReadingFrom: oldFile.workingCopy)
        defer { try? openOldMain.close() }
        let new = try stagedResult(
            in: directory,
            identity: identity,
            main: Data("new main".utf8),
            sidecars: ["-wal": Data("new wal".utf8)],
            marker: "new"
        )

        let boundary = GenerationPublicationProbe()
        let committed = try RemoteFileMaterializationCommit.publish(
            new,
            identity: identity,
            deadline: ConnectionDeadline(configuredSeconds: 60),
            timeoutEndpoint: .remoteFile("host:22"),
            isCancelled: { false },
            isCurrent: { true },
            didPublish: {
                boundary.capture(in: directory, fileName: "app.db")
            }
        )
        let selected = try #require(RemoteDatabaseFileStore.publishedGeneration(
            in: directory,
            fileName: "app.db"
        ))

        #expect(committed.workingCopy == new.generation.workingCopy)
        #expect(selected.workingCopy == new.generation.workingCopy)
        #expect(selected.manifest.downloadedSHA256 == "new")
        #expect(boundary.generationIdentifier == new.generation.identifier)
        #expect(boundary.manifestMarker == "new")
        #expect(boundary.main == Data("new main".utf8))
        #expect(boundary.sidecars["-wal"] == Data("new wal".utf8))
        #expect(try Data(contentsOf: selected.workingCopy) == Data("new main".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: selected.workingCopy.path + "-wal")) == Data("new wal".utf8))
        #expect(!FileManager.default.fileExists(atPath: selected.workingCopy.path + "-journal"))
        #expect(!FileManager.default.fileExists(atPath: selected.workingCopy.path + "-shm"))
        #expect(try openOldMain.readToEnd() == Data("old main".utf8))
        #expect(try Data(contentsOf: oldFile.workingCopy) == Data("old main".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: oldFile.workingCopy.path + "-wal")) == Data("old wal".utf8))
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: oldFile.workingCopy.path + "-journal"))
                == Data("old journal".utf8)
        )
    }

    @Test("Cancellation before selector publication leaves the old generation selected")
    func cancellationBeforePublicationKeepsOldGeneration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let old = try stagedResult(
            in: directory,
            identity: identity,
            sidecars: [
                "-wal": Data("old wal".utf8),
                "-journal": Data("old journal".utf8),
            ],
            marker: "old"
        )
        _ = try publish(old, identity: identity)
        let new = try stagedResult(in: directory, identity: identity, marker: "new")

        #expect(throws: SFTPError.cancelled) {
            try RemoteFileMaterializationCommit.publish(
                new,
                identity: identity,
                deadline: ConnectionDeadline(configuredSeconds: 60),
                timeoutEndpoint: .remoteFile("host:22"),
                isCancelled: { true },
                isCurrent: { true }
            )
        }
        RemoteDatabaseFileStore.discardUnpublishedGeneration(new.generation)

        let selected = try #require(RemoteDatabaseFileStore.publishedGeneration(
            in: directory,
            fileName: "app.db"
        ))
        #expect(selected.generation?.identifier == old.generation.identifier)
        #expect(selected.manifest.downloadedSHA256 == "old")
        #expect(!FileManager.default.fileExists(atPath: new.generation.directory.path))
    }

    @Test("Cancellation at the publication boundary cannot turn a committed generation into failure")
    func cancellationAfterPublicationReturnsCommittedGeneration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let old = try stagedResult(in: directory, identity: identity, marker: "old")
        _ = try publish(old, identity: identity)
        let new = try stagedResult(in: directory, identity: identity, marker: "new")

        let task = Task {
            try RemoteFileMaterializationCommit.publish(
                new,
                identity: identity,
                deadline: ConnectionDeadline(configuredSeconds: 60),
                timeoutEndpoint: .remoteFile("host:22"),
                isCancelled: { Task.isCancelled },
                isCurrent: { true },
                didPublish: {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        let committed = try await task.value

        #expect(task.isCancelled)
        #expect(committed.workingCopy == new.generation.workingCopy)
        let selected = try #require(RemoteDatabaseFileStore.publishedGeneration(
            in: directory,
            fileName: "app.db"
        ))
        #expect(selected.generation?.identifier == new.generation.identifier)
    }

    @Test("A partial failure at either SQLite sidecar keeps the old generation selected")
    func everyPartialSidecarFailureKeepsOldGeneration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let old = try stagedResult(
            in: directory,
            identity: identity,
            sidecars: [
                "-wal": Data("old wal".utf8),
                "-journal": Data("old journal".utf8),
            ],
            marker: "old"
        )
        _ = try publish(old, identity: identity)
        let files = [
            "/srv/app.db-wal": Data("complete wal".utf8),
            "/srv/app.db-journal": Data("complete journal".utf8),
        ]

        for suffix in ["-wal", "-journal"] {
            let generation = try RemoteDatabaseFileStore.prepareGeneration(in: directory, fileName: "app.db")
            try Data("new main".utf8).write(to: generation.workingCopy)
            let source = PartialFailingRemoteFileSource(
                files: files,
                failingPath: "/srv/app.db\(suffix)"
            )

            #expect(throws: SFTPError.cancelled) {
                try RemoteDatabaseFileTransfer.fetchSidecars(
                    from: source,
                    remotePath: "/srv/app.db",
                    sidecars: ["-wal", "-journal"],
                    stagingDirectory: generation.directory,
                    fileName: "app.db",
                    deadline: ConnectionDeadline(configuredSeconds: 60),
                    isCancelled: { false }
                )
            }

            let partial = URL(fileURLWithPath: generation.workingCopy.path + suffix)
            #expect(try Data(contentsOf: partial) == source.partialData)
            let selected = try #require(RemoteDatabaseFileStore.publishedGeneration(
                in: directory,
                fileName: "app.db"
            ))
            #expect(selected.generation?.identifier == old.generation.identifier)
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: selected.workingCopy.path + "-wal"))
                    == Data("old wal".utf8)
            )
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: selected.workingCopy.path + "-journal"))
                    == Data("old journal".utf8)
            )
            RemoteDatabaseFileStore.discardUnpublishedGeneration(generation)
        }
    }

    @Test("A missing required sidecar cannot publish an incomplete generation")
    func missingRequiredSidecarKeepsOldGeneration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let old = try stagedResult(in: directory, identity: identity, marker: "old")
        _ = try publish(old, identity: identity)
        let staged = try stagedResult(in: directory, identity: identity, marker: "new")
        let incomplete = RemoteFetchResult(
            generation: staged.generation,
            manifest: staged.manifest,
            plan: staged.plan,
            fetchedSidecars: ["-wal"]
        )

        #expect(throws: CocoaError.self) {
            try publish(incomplete, identity: identity)
        }
        let selected = try #require(RemoteDatabaseFileStore.publishedGeneration(
            in: directory,
            fileName: "app.db"
        ))
        #expect(selected.generation?.identifier == old.generation.identifier)
    }

    @Test("A corrupt staged manifest cannot replace the old selector")
    func corruptStagedManifestKeepsOldGeneration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let old = try stagedResult(in: directory, identity: identity, marker: "old")
        _ = try publish(old, identity: identity)
        let new = try stagedResult(in: directory, identity: identity, marker: "new")
        try Data("not a manifest".utf8).write(to: new.generation.manifestURL)

        var publicationFailed = false
        do {
            _ = try publish(new, identity: identity)
        } catch {
            publicationFailed = true
        }

        #expect(publicationFailed)
        let selected = try #require(RemoteDatabaseFileStore.publishedGeneration(
            in: directory,
            fileName: "app.db"
        ))
        #expect(selected.generation?.identifier == old.generation.identifier)
    }

    @Test("A selected generation is not reusable after a required sidecar disappears")
    func missingPublishedSidecarForcesRefetch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let generation = try stagedResult(
            in: directory,
            identity: identity,
            sidecars: ["-wal": Data("wal".utf8)],
            marker: "with-wal"
        )
        _ = try publish(generation, identity: identity)
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: generation.generation.workingCopy.path + "-wal")
        )

        #expect(RemoteDatabaseFileStore.publishedGeneration(in: directory, fileName: "app.db") == nil)
    }

    @Test("An expired deadline before selector publication leaves the old generation selected")
    func expiredDeadlineBeforePublicationKeepsOldGeneration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let old = try stagedResult(in: directory, identity: identity, marker: "old")
        _ = try publish(old, identity: identity)
        let new = try stagedResult(in: directory, identity: identity, marker: "new")
        let deadline = ConnectionDeadline(
            configuredSeconds: 5,
            instant: ContinuousClock.now.advanced(by: .seconds(-1))
        )

        #expect(throws: ConnectionTimeoutError.self) {
            try RemoteFileMaterializationCommit.publish(
                new,
                identity: identity,
                deadline: deadline,
                timeoutEndpoint: .remoteFile("host:22"),
                isCancelled: { false },
                isCurrent: { true }
            )
        }

        let selected = try #require(RemoteDatabaseFileStore.publishedGeneration(
            in: directory,
            fileName: "app.db"
        ))
        #expect(selected.generation?.identifier == old.generation.identifier)
    }

    @Test("A selector rename failure preserves the old selector")
    func selectorRenameFailureKeepsOldGeneration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let old = try stagedResult(in: directory, identity: identity, marker: "old")
        _ = try publish(old, identity: identity)
        let new = try stagedResult(in: directory, identity: identity, marker: "new")

        #expect(throws: CocoaError.self) {
            try RemoteDatabaseFileStore.publish(
                new.generation,
                requiredSidecars: new.fetchedSidecars,
                replaceReference: { _, _ in throw CocoaError(.fileWriteUnknown) }
            )
        }

        let selected = try #require(RemoteDatabaseFileStore.publishedGeneration(
            in: directory,
            fileName: "app.db"
        ))
        #expect(selected.generation?.identifier == old.generation.identifier)
        #expect(selected.manifest.downloadedSHA256 == "old")
    }

    @Test("Legacy flat copies remain reusable for basenames introduced by the generation store")
    func legacyFlatCopiesAvoidGenerationMetadataCollisions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = testIdentity()

        let names = [
            (remote: "active-generation", working: "active-generation"),
            (remote: "generations", working: "generations"),
            (remote: "manifest.json", working: "database-manifest.json"),
        ]
        for names in names {
            let directory = root.appendingPathComponent(names.remote, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let legacyPayload = Data("legacy \(names.remote)".utf8)
            let legacySidecar = Data("legacy wal \(names.remote)".utf8)
            try legacyPayload.write(to: directory.appendingPathComponent(names.working))
            try legacySidecar.write(to: directory.appendingPathComponent(names.working + "-wal"))
            let legacyManifest = manifest(identity: identity, marker: "legacy")
            try RemoteDatabaseFileStore.writeManifest(legacyManifest, to: directory)

            let legacy = try #require(RemoteDatabaseFileStore.publishedGeneration(
                in: directory,
                fileName: names.working
            ))
            #expect(legacy.generation == nil)
            #expect(try Data(contentsOf: legacy.workingCopy) == legacyPayload)

            let replacement = try stagedResult(
                in: directory,
                identity: identity,
                fileName: names.working,
                main: Data("new \(names.remote)".utf8),
                marker: "new"
            )
            _ = try publish(replacement, identity: identity)
            #expect(try Data(contentsOf: directory.appendingPathComponent(names.working)) == legacyPayload)
            #expect(
                try Data(contentsOf: directory.appendingPathComponent(names.working + "-wal"))
                    == legacySidecar
            )
            let selected = try #require(RemoteDatabaseFileStore.publishedGeneration(
                in: directory,
                fileName: names.working
            ))
            #expect(selected.generation?.identifier == replacement.generation.identifier)
        }
    }

    @Test("A generation selector cannot decode as a legacy flat manifest")
    func generationSelectorFailsLegacyManifestDecoding() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let generation = try stagedResult(in: directory, identity: identity, marker: "new")
        _ = try publish(generation, identity: identity)

        let selector = try Data(contentsOf: directory.appendingPathComponent(RemoteDatabaseFileStore.manifestName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect((try? decoder.decode(RemoteFileManifest.self, from: selector)) == nil)
    }

    @Test("An unsupported generation selector never falls back to stale flat bytes")
    func unsupportedSelectorDoesNotReuseLegacyPayload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let generation = try stagedResult(in: directory, identity: identity, marker: "new")
        _ = try publish(generation, identity: identity)
        try Data("stale flat".utf8).write(to: directory.appendingPathComponent("app.db"))
        let selectorURL = directory.appendingPathComponent(RemoteDatabaseFileStore.manifestName)
        let selectorData = try Data(contentsOf: selectorURL)
        var selector = try #require(JSONSerialization.jsonObject(with: selectorData) as? [String: Any])
        selector["formatVersion"] = 999
        try JSONSerialization.data(withJSONObject: selector).write(to: selectorURL)

        #expect(RemoteDatabaseFileStore.publishedGeneration(in: directory, fileName: "app.db") == nil)
    }

    @Test("Sidecar checks and downloads receive the original absolute deadline")
    func sidecarsKeepOriginalDeadline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DeadlineRecordingRemoteFileSource(files: ["/srv/app.db-wal": Data("wal".utf8)])
        let deadline = ConnectionDeadline(configuredSeconds: 60)

        let fetched = try RemoteDatabaseFileTransfer.fetchSidecars(
            from: source,
            remotePath: "/srv/app.db",
            sidecars: ["-wal"],
            stagingDirectory: directory,
            fileName: "app.db",
            deadline: deadline,
            isCancelled: { false }
        )

        #expect(fetched == ["-wal"])
        #expect(source.recordedDeadlines == [deadline, deadline])
    }

    // MARK: - Snapshot cleanup

    @Test("A timed-out snapshot download is cleaned without nohup and does not block the command")
    func noNohupSnapshotCleanupIsDetachedAndExact() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: false)
        let sleepStarted = directory.appendingPathComponent("sleep-started")
        let sleepRelease = directory.appendingPathComponent("sleep-release")
        defer { signalFile(sleepRelease) }
        try writeExecutable(
            """
            #!/bin/sh
            : > \(LibSSH2ExecChannel.shellQuoted(sleepStarted.path))
            while [ ! -e \(LibSSH2ExecChannel.shellQuoted(sleepRelease.path)) ]; do
                /bin/sleep 0.01
            done
            """,
            to: commandDirectory.appendingPathComponent("sleep")
        )
        try FileManager.default.createSymbolicLink(
            at: commandDirectory.appendingPathComponent("rm"),
            withDestinationURL: URL(fileURLWithPath: "/bin/rm")
        )
        let remoteDirectory = directory.appendingPathComponent("remote path", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: false)
        let injectionMarker = directory.appendingPathComponent("INJECTED")
        let remotePath = remoteDirectory.appendingPathComponent("app '; : > INJECTED; $HOME\n.db").path
        let endpoint = ConnectionTimeoutEndpoint.remoteFile("host:22")
        let session = ExecutableRemoteSnapshotSession(
            path: commandDirectory.path,
            timeoutEndpoint: endpoint,
            workingDirectory: directory
        )
        let deadline = ConnectionDeadline(
            configuredSeconds: 60,
            instant: ContinuousClock.now.advanced(by: .milliseconds(50))
        )

        let timedOut = await BoundedCall.resultOnItsOwnThread(
            within: .seconds(2),
            onDeadline: { signalFile(sleepRelease) }
        ) {
            do {
                _ = try RemoteDatabaseFileTransfer.fetchViaRemoteSnapshot(
                    session: session,
                    executable: "/usr/bin/true",
                    remotePath: remotePath,
                    staging: directory.appendingPathComponent("download.db"),
                    deadline: deadline,
                    progress: nil,
                    isCancelled: { false },
                    cleanupDelaySeconds: 1
                )
                return false
            } catch is ConnectionTimeoutError {
                return true
            } catch {
                return false
            }
        }

        #expect(timedOut == true)
        #expect(session.commandDuration < 2)
        #expect(waitForFileToAppear(sleepStarted, within: 1))
        #expect(!FileManager.default.fileExists(atPath: sleepRelease.path))
        #expect(!FileManager.default.fileExists(atPath: injectionMarker.path))
        let snapshotPath = try #require(session.downloadedPaths.first)
        #expect(session.snapshotExistedAtDownload)
        #expect(session.removeAttempts == [snapshotPath])
        #expect(session.effectiveImmediateRemovals.isEmpty)
        signalFile(sleepRelease)
        let removed = await BoundedCall.resultOnItsOwnThread(within: .seconds(2)) {
            waitForFileToDisappear(URL(fileURLWithPath: snapshotPath), within: 2)
        }
        #expect(removed == true)
        #expect(FileManager.default.fileExists(atPath: snapshotPath + "-neighbor"))
    }

    @Test("A successful snapshot download still removes its server file immediately")
    func successfulSnapshotUsesImmediateCleanup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("snapshot".utf8)
        let session = RecordingRemoteSnapshotSession(downloadBehavior: .success(payload))
        let destination = directory.appendingPathComponent("app.db")

        let result = try RemoteDatabaseFileTransfer.fetchViaRemoteSnapshot(
            session: session,
            executable: "sqlite3",
            remotePath: "/srv/app.db",
            staging: destination,
            deadline: ConnectionDeadline(configuredSeconds: 60),
            progress: nil,
            isCancelled: { false }
        )

        let snapshotPath = try #require(session.downloadedPaths.first)
        #expect(result.bytes == UInt64(payload.count))
        #expect(try Data(contentsOf: destination) == payload)
        #expect(session.removeAttempts == [snapshotPath])
        #expect(session.effectiveImmediateRemovals == [snapshotPath])
    }

    // MARK: - Killed remote command

    @Test("A signal-killed remote command does not report success")
    func signalKilledCommandIsNotSuccess() {
        let killed = RemoteCommandResult(exitStatus: 0, standardOutput: "", standardError: "", exitSignal: "KILL")
        #expect(!killed.succeeded)
        let clean = RemoteCommandResult(exitStatus: 0, standardOutput: "ok", standardError: "", exitSignal: nil)
        #expect(clean.succeeded)
    }

    // MARK: - Prune

    @Test("An abandoned working copy is removed and a recently used one is kept")
    func pruneRemovesOnlyStaleCopies() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        let stale = root.appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let maxAge: TimeInterval = 30 * 24 * 60 * 60
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(maxAge + 86_400))], ofItemAtPath: stale.path
        )

        RemoteDatabaseFileStore.pruneAbandoned(in: root, olderThan: maxAge, now: now)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("Pruning keeps an old identity while a materialization owns it")
    func pruneExcludesOwnedIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ownedIdentity = testIdentity()
        let owned = root.appendingPathComponent(ownedIdentity.storageKey, isDirectory: true)
        let abandoned = root.appendingPathComponent("abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-100)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: owned.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: abandoned.path)

        RemoteDatabaseFileStore.pruneAbandoned(
            in: root,
            olderThan: 10,
            now: now,
            excludingStorageKeys: [ownedIdentity.storageKey]
        )

        #expect(FileManager.default.fileExists(atPath: owned.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test("The first-lease cleanup keeps the selected generation and removes only inactive generation directories")
    func inactiveGenerationCleanupIsConservative() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = testIdentity()
        let active = try stagedResult(in: directory, identity: identity, marker: "active")
        _ = try publish(active, identity: identity)
        let inactive = try stagedResult(in: directory, identity: identity, marker: "inactive")
        let orphan = try RemoteDatabaseFileStore.prepareGeneration(in: directory, fileName: "app.db")
        let invalid = directory.appendingPathComponent(".tablepro-generation-not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        let generationShapedFile = directory.appendingPathComponent(".tablepro-generation-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: generationShapedFile)
        let legacy = directory.appendingPathComponent("legacy.db")
        try Data("legacy".utf8).write(to: legacy)

        RemoteDatabaseFileStore.pruneInactiveGenerations(in: directory)

        #expect(FileManager.default.fileExists(atPath: active.generation.directory.path))
        #expect(!FileManager.default.fileExists(atPath: inactive.generation.directory.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.directory.path))
        #expect(FileManager.default.fileExists(atPath: invalid.path))
        #expect(FileManager.default.fileExists(atPath: generationShapedFile.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Generation cleanup runs only before an identity's first lease")
    func generationCleanupDoesNotDeleteAnOpenPriorGenerationOnLaterLeases() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteDatabaseFileStore(root: root)
        let identity = testIdentity()
        let directory = root.appendingPathComponent(identity.storageKey, isDirectory: true)
        let first = try await store.withExclusiveAccess(to: identity) {
            let result = try stagedResult(
                in: directory,
                identity: identity,
                main: Data("generation-a".utf8),
                marker: "A"
            )
            _ = try publish(result, identity: identity)
            return result.generation
        }
        let openFirstGeneration = try FileHandle(forReadingFrom: first.workingCopy)
        defer { try? openFirstGeneration.close() }

        _ = try await store.withExclusiveAccess(to: identity) {
            let result = try stagedResult(
                in: directory,
                identity: identity,
                main: Data("generation-b".utf8),
                marker: "B"
            )
            return try publish(result, identity: identity)
        }
        try await store.withExclusiveAccess(to: identity) {}

        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        try openFirstGeneration.seek(toOffset: 0)
        #expect(try openFirstGeneration.readToEnd() == Data("generation-a".utf8))
    }

    // MARK: - Exclusive access

    @Test("A cancelled queued caller returns while the first caller still owns the file")
    func cancelledQueuedCallerDoesNotReleaseTheHolder() async throws {
        let store = RemoteDatabaseFileStore()
        let identity = RemoteFileIdentity(username: "user", host: "host", port: 22, path: "/database.sqlite")
        let holderEntered = RemoteFileStoreTestSignal()
        let releaseHolder = RemoteFileStoreTestSignal()
        let cancelledBodyEntered = RemoteFileStoreTestSignal()

        let holder = Task {
            try await store.withExclusiveAccess(to: identity) {
                await holderEntered.signal()
                await releaseHolder.wait()
            }
        }
        defer {
            holder.cancel()
            Task { await releaseHolder.signal() }
        }
        let holderStarted = await waitForRemoteFileSignal(holderEntered)
        guard holderStarted else {
            Issue.record("The first file-store lease did not start")
            return
        }

        let cancelled = Task {
            try await store.withExclusiveAccess(to: identity) {
                await cancelledBodyEntered.signal()
            }
        }
        defer { cancelled.cancel() }
        let cancelledQueued = await waitForRemoteFileWaiters(1, in: store, for: identity)
        #expect(cancelledQueued)

        cancelled.cancel()
        let cancellationReturned = await BoundedCall.result(within: .seconds(2)) {
            do {
                try await cancelled.value
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        #expect(cancellationReturned == true)
        #expect(!(await cancelledBodyEntered.hasSignalled))
        #expect(await store.waiterCount(for: identity) == 0)

        let nextBodyEntered = RemoteFileStoreTestSignal()
        let next = Task {
            try await store.withExclusiveAccess(to: identity) {
                await nextBodyEntered.signal()
            }
        }
        defer { next.cancel() }
        let nextQueued = await waitForRemoteFileWaiters(1, in: store, for: identity)
        #expect(nextQueued)
        #expect(!(await nextBodyEntered.hasSignalled))

        await releaseHolder.signal()
        let handoffCompleted = await BoundedCall.result(
            within: .seconds(2),
            onDeadline: {
                holder.cancel()
                next.cancel()
            },
            of: {
                do {
                    try await holder.value
                    try await next.value
                    return true
                } catch {
                    return false
                }
            }
        )

        #expect(handoffCompleted == true)
        #expect(await nextBodyEntered.hasSignalled)
        #expect(!(await cancelledBodyEntered.hasSignalled))
    }

    @Test("A queued caller reaches its deadline while the first caller still owns the file")
    func queuedCallerDeadlineDoesNotReleaseTheHolder() async throws {
        let store = RemoteDatabaseFileStore()
        let identity = RemoteFileIdentity(username: "user", host: "host", port: 22, path: "/database.sqlite")
        let holderEntered = RemoteFileStoreTestSignal()
        let releaseHolder = RemoteFileStoreTestSignal()
        let timedOutBodyEntered = RemoteFileStoreTestSignal()

        let holder = Task {
            try await store.withExclusiveAccess(to: identity) {
                await holderEntered.signal()
                await releaseHolder.wait()
            }
        }
        defer {
            holder.cancel()
            Task { await releaseHolder.signal() }
        }
        let holderStarted = await waitForRemoteFileSignal(holderEntered)
        guard holderStarted else {
            Issue.record("The first file-store lease did not start")
            return
        }

        let deadline = ConnectionDeadline(
            configuredSeconds: 30,
            instant: ContinuousClock.now.advanced(by: .seconds(1))
        )
        let timedOut = Task {
            try await store.withExclusiveAccess(to: identity, deadline: deadline) {
                await timedOutBodyEntered.signal()
            }
        }
        defer { timedOut.cancel() }
        let timedOutQueued = await waitForRemoteFileWaiters(1, in: store, for: identity)
        #expect(timedOutQueued)

        let result = await BoundedCall.result(within: .seconds(3)) {
            await timedOut.result
        }
        if case .some(.failure(let error)) = result {
            #expect((error as? ConnectionTimeoutError) == ConnectionTimeoutError(
                endpoint: .remoteFile("host:22"),
                configuredSeconds: 30
            ))
        } else {
            Issue.record("Expected the queued file access to reach its connection deadline")
        }
        #expect(!(await timedOutBodyEntered.hasSignalled))
        #expect(await store.waiterCount(for: identity) == 0)

        let nextBodyEntered = RemoteFileStoreTestSignal()
        let next = Task {
            try await store.withExclusiveAccess(to: identity) {
                await nextBodyEntered.signal()
            }
        }
        defer { next.cancel() }
        let nextQueued = await waitForRemoteFileWaiters(1, in: store, for: identity)
        #expect(nextQueued)
        #expect(!(await nextBodyEntered.hasSignalled))

        await releaseHolder.signal()
        let handoffCompleted = await BoundedCall.result(
            within: .seconds(2),
            onDeadline: {
                holder.cancel()
                next.cancel()
            },
            of: {
                do {
                    try await holder.value
                    try await next.value
                    return true
                } catch {
                    return false
                }
            }
        )

        #expect(handoffCompleted == true)
        #expect(await nextBodyEntered.hasSignalled)
        #expect(!(await timedOutBodyEntered.hasSignalled))
    }

    private func testIdentity() -> RemoteFileIdentity {
        RemoteFileIdentity(username: "user", host: "host", port: 22, path: "/srv/app.db")
    }

    private func manifest(identity: RemoteFileIdentity, marker: String) -> RemoteFileManifest {
        RemoteFileManifest(
            origin: identity.displayOrigin,
            username: identity.username,
            host: identity.host,
            port: identity.port,
            remotePath: identity.path,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            remoteSize: UInt64(marker.utf8.count),
            remoteModified: Date(timeIntervalSince1970: 1_700_000_000),
            remoteWriteAheadLogSize: nil,
            remoteWriteAheadLogModified: nil,
            downloadedSHA256: marker,
            snapshotMethod: .directCopy
        )
    }

    private func stagedResult(
        in directory: URL,
        identity: RemoteFileIdentity,
        fileName: String = "app.db",
        main: Data = Data("main".utf8),
        sidecars: [String: Data] = [:],
        marker: String
    ) throws -> RemoteFetchResult {
        let generation = try RemoteDatabaseFileStore.prepareGeneration(in: directory, fileName: fileName)
        try main.write(to: generation.workingCopy)
        for (suffix, data) in sidecars {
            try data.write(to: URL(fileURLWithPath: generation.workingCopy.path + suffix))
        }
        let manifest = manifest(identity: identity, marker: marker)
        try RemoteDatabaseFileStore.writeManifest(manifest, to: generation.directory)
        return RemoteFetchResult(
            generation: generation,
            manifest: manifest,
            plan: .directCopy(sidecars: sidecars.keys.sorted()),
            fetchedSidecars: Set(sidecars.keys)
        )
    }

    private func publish(
        _ result: RemoteFetchResult,
        identity: RemoteFileIdentity
    ) throws -> MaterializedRemoteFile {
        try RemoteFileMaterializationCommit.publish(
            result,
            identity: identity,
            deadline: ConnectionDeadline(configuredSeconds: 60),
            timeoutEndpoint: .remoteFile("host:22"),
            isCancelled: { false },
            isCurrent: { true }
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

private actor RemoteFileStoreTestSignal {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var hasSignalled = false

    func signal() {
        guard !hasSignalled else { return }
        hasSignalled = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func wait() async {
        guard !hasSignalled else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private func waitForRemoteFileWaiters(
    _ expectedCount: Int,
    in store: RemoteDatabaseFileStore,
    for identity: RemoteFileIdentity
) async -> Bool {
    await BoundedCall.result(within: .seconds(2)) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await store.waiterCount(for: identity) < expectedCount {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    } == true
}

private func waitForRemoteFileSignal(_ signal: RemoteFileStoreTestSignal) async -> Bool {
    await BoundedCall.result(
        within: .seconds(2),
        onDeadline: {
            Task { await signal.signal() }
        },
        of: {
            await signal.wait()
            return true
        }
    ) == true
}

private func signalFile(_ url: URL) {
    _ = FileManager.default.createFile(atPath: url.path, contents: Data())
}

private func waitForFileToAppear(_ url: URL, within seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

private func waitForFileToDisappear(_ url: URL, within seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if !FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return !FileManager.default.fileExists(atPath: url.path)
}

private struct StubRemoteFileSource: RemoteFileSource {
    let files: [String: Data]

    func exists(_ path: String, deadline: ConnectionDeadline) throws -> Bool {
        try deadline.check(endpoint: .remoteFile("stub:22"))
        return files[path] != nil
    }

    func download(
        remotePath: String,
        to localURL: URL,
        deadline: ConnectionDeadline,
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> (bytes: UInt64, sha256: String) {
        try deadline.check(endpoint: .remoteFile("stub:22"))
        guard let data = files[remotePath] else {
            throw SFTPError.noSuchFile(path: remotePath)
        }
        try data.write(to: localURL)
        return (bytes: UInt64(data.count), sha256: "")
    }
}

private struct PartialFailingRemoteFileSource: RemoteFileSource {
    let files: [String: Data]
    let failingPath: String
    let partialData = Data("partial".utf8)

    func exists(_ path: String, deadline: ConnectionDeadline) throws -> Bool {
        files[path] != nil
    }

    func download(
        remotePath: String,
        to localURL: URL,
        deadline: ConnectionDeadline,
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> (bytes: UInt64, sha256: String) {
        guard remotePath != failingPath else {
            try partialData.write(to: localURL)
            throw SFTPError.cancelled
        }
        guard let data = files[remotePath] else { throw SFTPError.noSuchFile(path: remotePath) }
        try data.write(to: localURL)
        return (UInt64(data.count), "")
    }
}

private final class GenerationPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedIdentifier: UUID?
    private var capturedManifestMarker: String?
    private var capturedMain: Data?
    private var capturedSidecars: [String: Data] = [:]

    var generationIdentifier: UUID? { lock.withLock { capturedIdentifier } }
    var manifestMarker: String? { lock.withLock { capturedManifestMarker } }
    var main: Data? { lock.withLock { capturedMain } }
    var sidecars: [String: Data] { lock.withLock { capturedSidecars } }

    func capture(in directory: URL, fileName: String) {
        let published = RemoteDatabaseFileStore.publishedGeneration(in: directory, fileName: fileName)
        let main = published.flatMap { try? Data(contentsOf: $0.workingCopy) }
        var sidecars: [String: Data] = [:]
        if let workingCopy = published?.workingCopy,
           let wal = try? Data(contentsOf: URL(fileURLWithPath: workingCopy.path + "-wal")) {
            sidecars["-wal"] = wal
        }
        lock.withLock {
            capturedIdentifier = published?.generation?.identifier
            capturedManifestMarker = published?.manifest.downloadedSHA256
            capturedMain = main
            capturedSidecars = sidecars
        }
    }
}

private final class DeadlineRecordingRemoteFileSource: RemoteFileSource, @unchecked Sendable {
    private let files: [String: Data]
    private let lock = NSLock()
    private var deadlines: [ConnectionDeadline] = []

    init(files: [String: Data]) {
        self.files = files
    }

    var recordedDeadlines: [ConnectionDeadline] {
        lock.withLock { deadlines }
    }

    func exists(_ path: String, deadline: ConnectionDeadline) throws -> Bool {
        lock.withLock { deadlines.append(deadline) }
        return files[path] != nil
    }

    func download(
        remotePath: String,
        to localURL: URL,
        deadline: ConnectionDeadline,
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> (bytes: UInt64, sha256: String) {
        lock.withLock { deadlines.append(deadline) }
        guard let data = files[remotePath] else {
            throw SFTPError.noSuchFile(path: remotePath)
        }
        try data.write(to: localURL)
        return (bytes: UInt64(data.count), sha256: "")
    }
}

private final class ExecutableRemoteSnapshotSession: RemoteSnapshotSession, @unchecked Sendable {
    private let path: String
    private let timeoutEndpoint: ConnectionTimeoutEndpoint
    private let workingDirectory: URL
    private let lock = NSLock()
    private var recordedDownloadedPaths: [String] = []
    private var recordedRemoveAttempts: [String] = []
    private var recordedEffectiveRemovals: [String] = []
    private var recordedSnapshotExistedAtDownload = false
    private var recordedCommandDuration: TimeInterval = 0

    init(path: String, timeoutEndpoint: ConnectionTimeoutEndpoint, workingDirectory: URL) {
        self.path = path
        self.timeoutEndpoint = timeoutEndpoint
        self.workingDirectory = workingDirectory
    }

    var downloadedPaths: [String] { lock.withLock { recordedDownloadedPaths } }
    var removeAttempts: [String] { lock.withLock { recordedRemoveAttempts } }
    var effectiveImmediateRemovals: [String] { lock.withLock { recordedEffectiveRemovals } }
    var snapshotExistedAtDownload: Bool { lock.withLock { recordedSnapshotExistedAtDownload } }
    var commandDuration: TimeInterval { lock.withLock { recordedCommandDuration } }

    func exists(_ path: String, deadline: ConnectionDeadline) throws -> Bool {
        false
    }

    func runRemoteCommand(_ command: String, deadline: ConnectionDeadline) throws -> RemoteCommandResult {
        let process = Process()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": path]
        process.currentDirectoryURL = workingDirectory
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { _ in completed.signal() }
        let started = Date()
        try process.run()
        guard completed.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            _ = completed.wait(timeout: .now() + 1)
            lock.withLock { recordedCommandDuration = Date().timeIntervalSince(started) }
            throw SFTPError.remoteCommandFailed(
                command: "snapshot cleanup test",
                status: -1,
                output: "the shell exceeded its watchdog"
            )
        }
        lock.withLock { recordedCommandDuration = Date().timeIntervalSince(started) }
        return RemoteCommandResult(
            exitStatus: process.terminationStatus,
            standardOutput: "",
            standardError: "",
            exitSignal: nil
        )
    }

    func download(
        remotePath: String,
        to localURL: URL,
        deadline: ConnectionDeadline,
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> (bytes: UInt64, sha256: String) {
        _ = FileManager.default.createFile(atPath: remotePath, contents: Data("snapshot".utf8))
        _ = FileManager.default.createFile(atPath: remotePath + "-neighbor", contents: Data("neighbor".utf8))
        lock.withLock {
            recordedDownloadedPaths.append(remotePath)
            recordedSnapshotExistedAtDownload = FileManager.default.fileExists(atPath: remotePath)
        }
        Thread.sleep(forTimeInterval: 0.1)
        throw deadline.timeoutError(for: timeoutEndpoint)
    }

    func remove(_ path: String, deadline: ConnectionDeadline) {
        lock.withLock { recordedRemoveAttempts.append(path) }
        guard !deadline.isExpired else { return }
        try? FileManager.default.removeItem(atPath: path)
        lock.withLock { recordedEffectiveRemovals.append(path) }
    }
}

private final class RecordingRemoteSnapshotSession: RemoteSnapshotSession {
    enum DownloadBehavior {
        case success(Data)
        case failure(any Error, delay: TimeInterval)
    }

    let downloadBehavior: DownloadBehavior
    private(set) var commands: [String] = []
    private(set) var downloadedPaths: [String] = []
    private(set) var removeAttempts: [String] = []
    private(set) var effectiveImmediateRemovals: [String] = []

    init(downloadBehavior: DownloadBehavior) {
        self.downloadBehavior = downloadBehavior
    }

    func exists(_ path: String, deadline: ConnectionDeadline) throws -> Bool {
        false
    }

    func runRemoteCommand(_ command: String, deadline: ConnectionDeadline) throws -> RemoteCommandResult {
        commands.append(command)
        return RemoteCommandResult(exitStatus: 0, standardOutput: "", standardError: "", exitSignal: nil)
    }

    func download(
        remotePath: String,
        to localURL: URL,
        deadline: ConnectionDeadline,
        progress: (@Sendable (UInt64, UInt64) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> (bytes: UInt64, sha256: String) {
        downloadedPaths.append(remotePath)
        switch downloadBehavior {
        case .success(let data):
            try data.write(to: localURL)
            return (UInt64(data.count), "hash")
        case .failure(let error, let delay):
            Thread.sleep(forTimeInterval: delay)
            throw error
        }
    }

    func remove(_ path: String, deadline: ConnectionDeadline) {
        removeAttempts.append(path)
        guard !deadline.isExpired else { return }
        effectiveImmediateRemovals.append(path)
    }
}
