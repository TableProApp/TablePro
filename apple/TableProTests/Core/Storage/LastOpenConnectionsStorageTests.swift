//
//  LastOpenConnectionsStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct LastOpenConnectionsStorageTests {
    private let directory: URL
    private let storage: LastOpenConnectionsStorage

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastOpenConnectionsStorageTests-\(UUID().uuidString)", isDirectory: true)
        storage = LastOpenConnectionsStorage(directory: directory)
    }

    private var legacyURL: URL { directory.appendingPathComponent("LastOpenConnections.json") }
    private var sessionURL: URL { directory.appendingPathComponent("LastSession.json") }

    private func legacyIds() throws -> [UUID] {
        try JSONDecoder().decode([UUID].self, from: Data(contentsOf: legacyURL))
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.modificationDate] as? Date)
    }

    private func touch(_ url: URL, after other: URL) throws {
        let later = try modificationDate(of: other).addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
    }

    @Test("A relaunch brings back every strip entry in order, and only the live ones dial")
    func relaunchWithCanceledAndDisconnectedConnections() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let mysql = UUID()
        let redis = UUID()
        let canceled = UUID()
        let disconnected = UUID()
        func candidate(_ id: UUID, _ offset: TimeInterval, _ phase: ConnectionWindowPhase) -> RecoveryCandidate {
            RecoveryCandidate(
                connectionId: id,
                openedAt: start.addingTimeInterval(offset),
                phase: phase,
                isActivated: phase == .connected
            )
        }
        let candidates = [
            candidate(disconnected, 3, .unavailable(.disconnectedByUser)),
            candidate(mysql, 0, .connected),
            candidate(canceled, 2, .unavailable(.cancelled)),
            candidate(redis, 1, .connected),
        ]

        storage.save(RecoveryConnectionList.lastSession(from: candidates, shownConnectionId: redis))
        let relaunched = LastOpenConnectionsStorage(directory: directory).load()

        #expect(relaunched.connections == [
            LastSession.Connection(id: mysql, reconnects: true),
            LastSession.Connection(id: redis, reconnects: true),
            LastSession.Connection(id: canceled, reconnects: false),
            LastSession.Connection(id: disconnected, reconnects: false),
        ])
        #expect(relaunched.shownConnectionId == redis)
    }

    @Test("The file older builds read holds only the connections that dial")
    func legacyFileHoldsOnlyReconnectingIds() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = UUID()
        let canceled = UUID()

        storage.save(LastSession(connections: [
            LastSession.Connection(id: canceled, reconnects: false),
            LastSession.Connection(id: live, reconnects: true),
        ]))

        #expect(try legacyIds() == [live])
    }

    @Test("A session with nothing to dial leaves an older build nothing to dial")
    func nothingToDialWritesAnEmptyLegacyList() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let canceled = LastSession(connections: [LastSession.Connection(id: UUID(), reconnects: false)])
        storage.save(LastSession(connections: [LastSession.Connection(id: UUID(), reconnects: true)]))

        storage.save(canceled)

        #expect(try legacyIds().isEmpty)
        #expect(storage.load() == canceled)
    }

    @Test("A list written by an older build reopens every connection it names")
    func legacyFileAloneReconnectsEverything() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = UUID()
        let second = UUID()
        try JSONEncoder().encode([first, second]).write(to: legacyURL)

        #expect(storage.load() == LastSession(connections: [
            LastSession.Connection(id: first, reconnects: true),
            LastSession.Connection(id: second, reconnects: true),
        ]))
    }

    @Test("A list an older build wrote after the session wins over it")
    func olderBuildsNewerListWins() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let after = UUID()
        storage.save(LastSession(connections: [
            LastSession.Connection(id: UUID(), reconnects: true),
            LastSession.Connection(id: UUID(), reconnects: false),
        ]))

        try JSONEncoder().encode([after]).write(to: legacyURL)
        try touch(legacyURL, after: sessionURL)

        #expect(storage.load() == LastSession(connections: [LastSession.Connection(id: after, reconnects: true)]))
    }

    @Test("A save cut short before the legacy list keeps the newer session")
    func interruptedSaveKeepsTheNewerSession() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let connected = LastSession.Connection(id: UUID(), reconnects: true)
        let canceled = LastSession.Connection(id: UUID(), reconnects: false)
        storage.save(LastSession(connections: [connected, canceled]))
        let newer = LastSession(connections: [connected, canceled, LastSession.Connection(id: UUID(), reconnects: true)])

        try JSONEncoder().encode(newer).write(to: sessionURL)
        try touch(sessionURL, after: legacyURL)

        #expect(storage.load() == newer)
    }

    @Test("A first save writes the legacy list before the session, and a later save after it")
    func saveOrderLeavesARecoverableFileBehind() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = LastSession(connections: [LastSession.Connection(id: UUID(), reconnects: false)])
        let second = LastSession(connections: [LastSession.Connection(id: UUID(), reconnects: true)])

        storage.save(first)
        #expect(try modificationDate(of: legacyURL) <= modificationDate(of: sessionURL))

        storage.save(second)
        #expect(try modificationDate(of: legacyURL) >= modificationDate(of: sessionURL))
        #expect(storage.load() == second)
    }

    @Test("A list an older build removed reopens nothing")
    func olderBuildsRemovedListReopensNothing() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        storage.save(LastSession(connections: [LastSession.Connection(id: UUID(), reconnects: true)]))

        try FileManager.default.removeItem(at: legacyURL)

        #expect(storage.load() == .empty)
    }

    @Test("Windows closing after the quit save leave the saved session alone")
    func sealedStorageKeepsTheQuitSave() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let notConnected = LastSession(connections: [
            LastSession.Connection(id: UUID(), reconnects: false),
            LastSession.Connection(id: UUID(), reconnects: false),
        ])
        storage.save(notConnected)

        storage.seal()
        storage.save(.empty)
        storage.save(LastSession(connections: [LastSession.Connection(id: UUID(), reconnects: true)]))

        #expect(LastOpenConnectionsStorage(directory: directory).load() == notConnected)
    }

    @Test("An empty session clears both files")
    func emptySessionClearsBothFiles() {
        defer { try? FileManager.default.removeItem(at: directory) }
        storage.save(LastSession(connections: [LastSession.Connection(id: UUID(), reconnects: true)]))

        storage.save(.empty)

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
        #expect(storage.load() == .empty)
    }
}
