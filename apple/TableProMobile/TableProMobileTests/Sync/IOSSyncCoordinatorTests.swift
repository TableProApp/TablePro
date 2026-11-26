import CloudKit
import Foundation
import TableProFFI
@testable import TableProMobile
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
private final class Fixture {
    let database = HeldCloudKitDatabase()
    let transport: CloudKitCoreTransport
    let engine = FakeIOSSyncEngine()
    let notifications = NotificationCenter()
    var enabled = true
    var passesFinished = 0
    private let suite: UserDefaults
    let metadata: SyncMetadataStorage
    private(set) var coordinator: IOSSyncCoordinator!

    init() throws {
        suite = try #require(UserDefaults(suiteName: "com.TablePro.tests.IOSSync.\(UUID().uuidString)"))
        metadata = SyncMetadataStorage(userDefaults: suite)
        transport = CloudKitCoreTransport(database: database)
        let host = IOSSyncEngineHost(transport: transport) { [engine] _ in engine }
        coordinator = IOSSyncCoordinator(
            host: host,
            metadata: metadata,
            isEnabled: { [unowned self] in enabled },
            database: database,
            notificationCenter: notifications,
            makeNetworkMonitor: { nil },
            activationClock: ManualClock(),
            pushRegistrar: .inert
        )
        coordinator.onPassFinished = { [unowned self] in passesFinished += 1 }
    }

    var passes: [PassReasonTag] {
        engine.read { $0.passes }
    }

    var providers: [SyncProviderTag] {
        engine.read { $0.providers }
    }

    // What the engine's pass sends: one batch, then another, as an upload of two batches does.
    func uploadTwoBatches() {
        let transport = transport
        engine.update { state in
            state.pass = { _ in
                for name in ["Tag_A", "Tag_B"] {
                    _ = try? await transport.modify(
                        account: "_alice",
                        saves: [CloudKitRecord(recordType: "ConnectionTag", name: name, systemFields: nil, createdMs: nil, fields: [])],
                        deletes: []
                    )
                }
            }
        }
    }
}

@MainActor
struct IOSSyncCoordinatorTests {
    @Test("With the switch on, launch tells the engine iCloud and runs a pass, with the transport open")
    func launchRunsAPass() async throws {
        let fixture = try Fixture()

        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        #expect(fixture.providers == [.icloud])
        #expect(fixture.passes == [.launch])
        #expect(!fixture.transport.isClosed)
        #expect(fixture.coordinator.status == .idle)
    }

    @Test("With the switch off, nothing opens the engine and the transport stays closed")
    func switchOffRunsNothing() async throws {
        let fixture = try Fixture()
        fixture.enabled = false

        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        #expect(fixture.passes.isEmpty)
        #expect(fixture.transport.isClosed)
        #expect(fixture.coordinator.status == .disabled(.userDisabled))
    }

    @Test("iCloud turned off during an upload stops it: the batch in flight is cancelled and no later one is sent")
    func turningOffStopsAnUploadInFlight() async throws {
        let fixture = try Fixture()
        fixture.database.holdNextModify()
        fixture.uploadTwoBatches()
        fixture.coordinator.start()
        try await waitUntil { fixture.database.modifyStarted == 1 }

        fixture.enabled = false
        fixture.coordinator.setEnabled(false)
        await fixture.coordinator.passesFinished()
        try await waitUntil { fixture.providers.last == .off }

        #expect(fixture.database.modifiesCancelled == 1)
        #expect(fixture.database.modifyStarted == 1)
        #expect(fixture.transport.isClosed)
        #expect(fixture.coordinator.status == .disabled(.userDisabled))
    }

    @Test("Each pass the engine finished tells the app once, so the stores are read again")
    func eachFinishedPassIsReported() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        await fixture.coordinator.sync(.userRequest)

        #expect(fixture.passes == [.launch, .person])
        #expect(fixture.passesFinished == 2)
        #expect(fixture.coordinator.lastSyncDate == Date(timeIntervalSince1970: 2))
    }

    @Test("A CloudKit notice asks the engine for a pass")
    func noticeRunsAPass() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        await fixture.coordinator.sync(.remoteChange)

        #expect(fixture.passes == [.launch, .cloudKitPush])
    }

    @Test("Upload Again asks the engine only after the data was removed from iCloud")
    func uploadAgainNeedsARemovedZone() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        await fixture.coordinator.uploadAgain()
        #expect(fixture.engine.read { $0.uploadsAgain } == 0)

        fixture.engine.update { $0.info.phase = .zoneRemoved }
        await fixture.coordinator.sync(.userRequest)
        #expect(fixture.coordinator.status == .error(.blocked(.dataDeletedFromICloud)))
        await fixture.coordinator.uploadAgain()

        #expect(fixture.engine.read { $0.uploadsAgain } == 1)
        #expect(fixture.passes.last == .person)
    }

    @Test("Each trigger the app has asks the engine for the pass that reads what it names")
    func triggersMapToPassReasons() {
        let reasons = [SyncTrigger.launch, .activation, .remoteChange, .localChange, .accountChange, .networkRestored, .userRequest]
            .map(IOSSyncCoordinator.reason(for:))

        #expect(reasons == [.launch, .foreground, .cloudKitPush, .journal, .accountChanged, .networkBack, .person])
    }
}
