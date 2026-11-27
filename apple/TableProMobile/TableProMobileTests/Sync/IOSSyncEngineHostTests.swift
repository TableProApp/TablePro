import Combine
import Foundation
import TableProFFI
@testable import TableProMobile
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
struct IOSSyncEngineHostTests {
    @Test("A sign-in change opens the service again for the same provider and flushes the one it replaced")
    func signInChangeReopens() async throws {
        var opened: [SyncProviderTag] = []
        var engines: [FakeIOSSyncEngine] = []
        let host = IOSSyncEngineHost(transport: CloudKitCoreTransport(database: HeldCloudKitDatabase())) { provider, _ in
            opened.append(provider)
            let engine = FakeIOSSyncEngine()
            engines.append(engine)
            return engine
        }
        var reopenings = 0
        let observer = host.reopened.sink { reopenings += 1 }
        defer { observer.cancel() }

        let first = try await host.engine(for: .tableproSync)
        host.signInChanged()
        try await waitUntil { reopenings == 1 }
        let second = try await host.engine(for: .tableproSync)

        #expect(opened == [.tableproSync, .tableproSync])
        #expect(first !== second)
        try await waitUntil { engines[0].read { $0.flushes } == 1 }
    }

    @Test("The sign-in the service opened under is kept for the next open")
    func serviceAccountIsKept() async throws {
        var kept: [String?] = []
        let engine = FakeIOSSyncEngine()
        engine.update { $0.serviceAccount = "acct_alice@tablepro.app" }
        let host = IOSSyncEngineHost(
            transport: CloudKitCoreTransport(database: HeldCloudKitDatabase()),
            keepServiceAccount: { kept.append($0) }
        ) { _, _ in engine }

        _ = try await host.engine(for: .tableproSync)

        #expect(kept == ["acct_alice@tablepro.app"])
    }

    @Test("A category change made while the service opens reaches it once it is open")
    func categoriesWaitForAnOpen() async throws {
        let engine = FakeIOSSyncEngine()
        let gate = AsyncGate()
        let host = IOSSyncEngineHost(transport: CloudKitCoreTransport(database: HeldCloudKitDatabase())) { _, _ in
            await gate.wait()
            return engine
        }
        let categories = SyncCategoriesArg(offKinds: ["saved_query"], passwords: false)
        let opening = Task { try await host.engine(for: .tableproSync) }
        await gate.arrived(1)

        let told = Task { await host.setCategories(categories) }
        await gate.open()
        _ = try await opening.value
        await told.value

        #expect(engine.read { $0.categories } == [categories])
    }

    @Test("Closing the open service flushes it, and the next caller opens a new one")
    func closeRetiresTheService() async throws {
        var engines: [FakeIOSSyncEngine] = []
        let host = IOSSyncEngineHost(transport: CloudKitCoreTransport(database: HeldCloudKitDatabase())) { _, _ in
            let engine = FakeIOSSyncEngine()
            engines.append(engine)
            return engine
        }

        let first = try await host.engine(for: .tableproSync)
        host.close()
        #expect(host.openedEngine(for: .off) == nil)
        let second = try await host.engine(for: .off)

        #expect(first !== second)
        try await waitUntil { engines[0].read { $0.flushes } == 1 }
    }

    @Test("The categories reach the open service whichever provider opened it, and none opens for them")
    func categoriesReachTheOpenService() async throws {
        var opens = 0
        let engine = FakeIOSSyncEngine()
        let host = IOSSyncEngineHost(transport: CloudKitCoreTransport(database: HeldCloudKitDatabase())) { _, _ in
            opens += 1
            return engine
        }
        let categories = SyncCategoriesArg(offKinds: ["ssh_profile"], passwords: true)

        await host.setCategories(categories)
        #expect(opens == 0)

        _ = try await host.engine(for: .icloud)
        await host.setCategories(categories)
        #expect(engine.read { $0.categories } == [categories])
    }
}
