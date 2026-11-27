import Combine
import Foundation
import TableProFFI
@testable import TableProMobile
import TableProSyncTransport
import TableProTestSupport
import Testing

// The moves over one fake service the host hands out for every provider, as the core's service serves Off too.
@MainActor
private final class Fixture {
    let engine = FakeIOSSyncEngine()
    let transport = CloudKitCoreTransport(database: HeldCloudKitDatabase())
    let changes = PassthroughSubject<Void, Never>()
    var provider: SyncProviderTag
    var stored: [SyncProviderTag] = []
    var session: String? = "session_a"
    var managed = ManagedAppConfiguration.unmanaged
    var passesFinished = 0
    private(set) var moves: IOSProviderMoves!

    init(provider: SyncProviderTag) {
        self.provider = provider
        transport.close()
        moves = IOSProviderMoves(host: IOSProviderMoveHost(
            engine: { [engine] _ in engine },
            openedEngine: { [engine] _ in engine },
            engineChanges: changes.eraseToAnyPublisher(),
            iCloudRuns: { [unowned self] in self.provider == .icloud },
            passesFinished: { [unowned self] in passesFinished += 1 },
            transport: transport,
            choices: { [unowned self] in managed.syncChoices },
            provider: { [unowned self] in managed.settledProvider(self.provider) },
            setProvider: { [unowned self] next in
                self.provider = next
                stored.append(next)
            },
            session: { [unowned self] in session }
        ))
    }
}

@MainActor
struct IOSProviderMovesTests {
    @Test("A first upload from Off chooses TablePro Sync, stores it, and runs the first pass")
    func firstUploadFromOff() async throws {
        let fixture = Fixture(provider: .off)

        let outcome = try await fixture.moves.moveToService(confirmedUnder: "session_a")

        #expect(outcome == .moved)
        #expect(fixture.stored == [.tableproSync])
        #expect(fixture.engine.read { $0.providers } == [.tableproSync])
        #expect(fixture.engine.read { $0.passes } == [.person])
        // From Off there is no iCloud pass to wait for.
        #expect(fixture.passesFinished == 0)
    }

    @Test("From iCloud the move waits for iCloud's passes and choices before the first TablePro Sync pass")
    func moveFromICloudWaitsForICloud() async throws {
        let fixture = Fixture(provider: .icloud)

        _ = try await fixture.moves.moveToService(confirmedUnder: "session_a")

        #expect(fixture.stored == [.tableproSync])
        #expect(fixture.passesFinished == 1)
        #expect(fixture.engine.read { $0.passes } == [.person])
    }

    @Test("A device without the account's keys uploads nothing and says which step comes first")
    func noKeysUploadsNothing() async throws {
        let fixture = Fixture(provider: .off)
        fixture.engine.update { $0.keys = .noKeys }

        let outcome = try await fixture.moves.moveToService(confirmedUnder: "session_a")

        #expect(outcome == .needsKeys(.noKeys))
        #expect(fixture.stored.isEmpty)
        #expect(fixture.engine.read { $0.providers }.isEmpty)
    }

    @Test("A move confirmed under another sign-in goes nowhere")
    func anotherSignInStopsTheMove() async {
        let fixture = Fixture(provider: .off)
        fixture.session = "session_b"

        await #expect(throws: ProviderMoveError.signInChanged) {
            _ = try await fixture.moves.moveToService(confirmedUnder: "session_a")
        }
        #expect(fixture.stored.isEmpty)
    }

    @Test("A server that keeps no personal data takes no upload")
    func serverRefusesPersonalData() async {
        let fixture = Fixture(provider: .off)
        fixture.engine.update {
            $0.scopes = [ScopeStatusInfo(scope: "personal", writable: true, personalSync: false, passwordSync: nil, historySync: nil)]
        }
        fixture.moves.engineChanged()

        await #expect(throws: ProviderMoveError.serverRefusesPersonalSync) {
            _ = try await fixture.moves.moveToService(confirmedUnder: "session_a")
        }
    }

    @Test("Values that leave TablePro Sync out refuse the move")
    func managedValuesRefuseTheMove() async {
        let fixture = Fixture(provider: .off)
        fixture.managed = ManagedAppConfiguration(personalSyncProvider: ["off", "icloud"])

        await #expect(throws: ProviderMoveError.notAllowed) {
            _ = try await fixture.moves.moveToService(confirmedUnder: "session_a")
        }
    }

    @Test("Turning off stores Off and takes the engine off TablePro Sync")
    func turnOffStopsTheEngine() async {
        let fixture = Fixture(provider: .tableproSync)
        fixture.engine.update { $0.info.provider = .tableproSync }

        await fixture.moves.turnOff()

        #expect(fixture.stored == [.off])
        #expect(fixture.engine.read { $0.providers } == [.off])
    }

    @Test("The move back opens CloudKit for the deletions, stores iCloud, and leaves the transport to the coordinator")
    func moveBackToICloud() async throws {
        let fixture = Fixture(provider: .tableproSync)

        try await fixture.moves.moveToICloud(confirmedDeletions: 4, confirmedUnder: "session_a")

        #expect(fixture.engine.read { $0.movesBack } == [4])
        #expect(fixture.stored == [.icloud])
        // iCloud runs now, so the coordinator keeps the transport it opened.
        #expect(!fixture.transport.isClosed)
    }

    @Test("Deleting the iCloud data opens CloudKit for the call alone while the device is not on iCloud")
    func deleteICloudData() async throws {
        let fixture = Fixture(provider: .tableproSync)

        try await fixture.moves.deleteICloudData()

        #expect(fixture.engine.read { $0.zoneDeletions } == 1)
        #expect(fixture.transport.isClosed)
    }

    @Test("A TablePro Sync pass that finished tells the stores to read again, once per pass")
    func finishedPassReloadsTheStores() {
        let fixture = Fixture(provider: .tableproSync)
        var reloads = 0
        fixture.moves.onPassFinished = { reloads += 1 }
        fixture.engine.update {
            $0.info.provider = .tableproSync
            $0.info.lastPassMs = 1_000
        }

        fixture.moves.engineChanged()
        fixture.moves.engineChanged()

        #expect(reloads == 1)
    }

    @Test("Coming forward on TablePro Sync asks for a pass, unless one just finished")
    func foregroundPass() async {
        let fixture = Fixture(provider: .tableproSync)

        await fixture.moves.sceneBecameActive()
        #expect(fixture.engine.read { $0.passes } == [.foreground])

        fixture.engine.update { $0.info.lastPassMs = Int64(Date().timeIntervalSince1970 * 1_000) }
        fixture.moves.engineChanged()
        await fixture.moves.sceneBecameActive()
        #expect(fixture.engine.read { $0.passes } == [.foreground])
    }

    @Test("Another account's prompt is answered for the account it named, then a pass runs")
    func newIdentityChoice() async throws {
        let fixture = Fixture(provider: .tableproSync)
        let plan = try await fixture.moves.planNewIdentity()

        try await fixture.moves.chooseForNewIdentity(.moveMyData, for: plan)

        #expect(fixture.engine.read { $0.identityChoices } == [.moveMyData])
        #expect(fixture.engine.read { $0.passes } == [.person])
    }
}
