import Combine
import Foundation
@testable import TablePro
import TableProFFI
import Testing

private final class CopyingKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private var calls = 0

    var copies: Int {
        lock.withLock { calls }
    }

    init(answers: [Bool]) {
        self.answers = answers
    }

    func writeString(_ value: String, forKey key: String) -> Bool { true }
    func readStringResult(forKey key: String) -> KeychainStringResult { .notFound }
    func delete(forKey key: String) {}

    func addDeviceOnlyCopies() -> Bool {
        lock.withLock {
            calls += 1
            return answers.isEmpty ? true : answers.removeFirst()
        }
    }
}

@MainActor
struct KeychainProviderFollowerTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private var state: KeychainProviderState {
        KeychainProviderState.stored(in: suite.defaults)
    }

    @Test("TablePro Sync adds the device-only copies and marks them added")
    func tableProSyncAddsCopies() async {
        let keychain = CopyingKeychain(answers: [true])
        let follower = KeychainProviderFollower(keychain: keychain, defaults: suite.defaults)

        follower.follow(.tableproSync)
        #expect(state == KeychainProviderState(onTableProSync: true, deviceCopiesAdded: false))
        await follower.copiesSettled()

        #expect(keychain.copies == 1)
        #expect(state == KeychainProviderState(onTableProSync: true, deviceCopiesAdded: true))
    }

    @Test("Copies a locked Keychain refused are tried again on the next report, then marked")
    func unfinishedCopiesAreTriedAgain() async {
        let keychain = CopyingKeychain(answers: [false, true])
        let follower = KeychainProviderFollower(keychain: keychain, defaults: suite.defaults)

        follower.follow(.tableproSync)
        await follower.copiesSettled()
        #expect(!state.deviceCopiesAdded)

        follower.follow(.tableproSync)
        await follower.copiesSettled()

        #expect(keychain.copies == 2)
        #expect(state.deviceCopiesAdded)
    }

    @Test("Back on iCloud or off, the password sync switch decides again", arguments: [SyncProviderTag.icloud, .off])
    func leavingTableProSyncClearsTheState(provider: SyncProviderTag) async {
        let follower = KeychainProviderFollower(keychain: CopyingKeychain(answers: [true]), defaults: suite.defaults)
        follower.follow(.tableproSync)
        await follower.copiesSettled()

        follower.follow(provider)

        #expect(state == .followsPasswordSync)
    }

    @Test("Copies that finish after a move back mark nothing")
    func lateCopiesMarkNothing() async {
        let keychain = CopyingKeychain(answers: [true])
        let follower = KeychainProviderFollower(keychain: keychain, defaults: suite.defaults)

        follower.follow(.tableproSync)
        follower.follow(.icloud)
        await follower.copiesSettled()

        #expect(state == .followsPasswordSync)
    }

    @Test("Each status the engine reports is followed, and a launch finishes copies owed from the last one")
    func followsTheEngineAndResumesAtLaunch() async {
        KeychainProviderState(onTableProSync: true, deviceCopiesAdded: false).store(in: suite.defaults)
        let keychain = CopyingKeychain(answers: [true])
        let follower = KeychainProviderFollower(keychain: keychain, defaults: suite.defaults)
        let changes = PassthroughSubject<Void, Never>()
        var reported: SyncProviderTag?

        follower.start(changes: changes.eraseToAnyPublisher()) { reported }
        await follower.copiesSettled()
        #expect(state.deviceCopiesAdded)

        reported = .icloud
        changes.send()

        #expect(state == .followsPasswordSync)
    }

    @Test("A status with no provider changes nothing")
    func noProviderChangesNothing() {
        KeychainProviderState(onTableProSync: true, deviceCopiesAdded: true).store(in: suite.defaults)
        let follower = KeychainProviderFollower(keychain: CopyingKeychain(answers: []), defaults: suite.defaults)
        let changes = PassthroughSubject<Void, Never>()

        follower.start(changes: changes.eraseToAnyPublisher()) { nil }
        changes.send()

        #expect(state == KeychainProviderState(onTableProSync: true, deviceCopiesAdded: true))
    }
}
