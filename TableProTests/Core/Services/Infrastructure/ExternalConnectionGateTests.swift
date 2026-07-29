import Foundation
@testable import TablePro
import Testing

@MainActor
private final class SpyPrompt: ExternalConnectionPrompting {
    private let decision: ExternalConnectionDecision

    private(set) var callCount = 0
    private(set) var offeredAlwaysAllow: Bool?

    init(decision: ExternalConnectionDecision) {
        self.decision = decision
    }

    func prompt(for connection: DatabaseConnection, offerAlwaysAllow: Bool) async -> ExternalConnectionDecision {
        callCount += 1
        offeredAlwaysAllow = offerAlwaysAllow
        return decision
    }
}

@MainActor
@Suite("ExternalConnectionGate")
struct ExternalConnectionGateTests {
    private func makeStore() throws -> ExternalConnectionTrustStore {
        let suite = "ExternalConnectionGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return ExternalConnectionTrustStore(defaults: defaults)
    }

    private func ddevConnection(port: Int = 32_770) -> DatabaseConnection {
        DatabaseConnection(
            name: "ddev-shop", host: "127.0.0.1", port: port,
            database: "db", username: "db", type: .mysql
        )
    }

    private func remoteConnection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Prod", host: "db.example.com", port: 3_306,
            database: "shop", username: "root", type: .mysql
        )
    }

    @Test("Connect authorizes once without persisting trust")
    func connectDoesNotPersist() async throws {
        let store = try makeStore()
        let prompt = SpyPrompt(decision: .connect)
        let gate = ExternalConnectionGate(trustStore: store, prompt: prompt)

        let authorized = await gate.authorize(ddevConnection(), scopeName: "ddev-shop")

        #expect(authorized)
        #expect(store.entries().isEmpty)
        #expect(prompt.callCount == 1)
        #expect(prompt.offeredAlwaysAllow == true)
    }

    @Test("Cancel refuses and persists nothing")
    func cancelRefuses() async throws {
        let store = try makeStore()
        let prompt = SpyPrompt(decision: .cancel)
        let gate = ExternalConnectionGate(trustStore: store, prompt: prompt)

        let authorized = await gate.authorize(ddevConnection(), scopeName: "ddev-shop")

        #expect(authorized == false)
        #expect(store.entries().isEmpty)
    }

    @Test("Always Allow persists trust and the next open never prompts")
    func alwaysAllowSkipsSecondPrompt() async throws {
        let store = try makeStore()
        let prompt = SpyPrompt(decision: .alwaysAllow)
        let gate = ExternalConnectionGate(trustStore: store, prompt: prompt)

        #expect(await gate.authorize(ddevConnection(), scopeName: "ddev-shop"))
        #expect(prompt.callCount == 1)

        let restarted = ddevConnection(port: 49_153)
        #expect(await gate.authorize(restarted, scopeName: "ddev-shop"))
        #expect(prompt.callCount == 1)
    }

    @Test("A remote host is never offered Always Allow")
    func remoteHostGetsNoAlwaysAllow() async throws {
        let store = try makeStore()
        let prompt = SpyPrompt(decision: .connect)
        let gate = ExternalConnectionGate(trustStore: store, prompt: prompt)

        _ = await gate.authorize(remoteConnection(), scopeName: "anything")

        #expect(prompt.offeredAlwaysAllow == false)
    }

    @Test("A remote host always prompts, even if the prompt answers Always Allow")
    func remoteHostAlwaysPrompts() async throws {
        let store = try makeStore()
        let prompt = SpyPrompt(decision: .alwaysAllow)
        let gate = ExternalConnectionGate(trustStore: store, prompt: prompt)

        #expect(await gate.authorize(remoteConnection(), scopeName: "anything"))
        #expect(store.entries().isEmpty)

        #expect(await gate.authorize(remoteConnection(), scopeName: "anything"))
        #expect(prompt.callCount == 2)
    }

    @Test("Trusting one DDEV project does not silence another")
    func trustDoesNotLeakAcrossProjects() async throws {
        let store = try makeStore()
        let prompt = SpyPrompt(decision: .alwaysAllow)
        let gate = ExternalConnectionGate(trustStore: store, prompt: prompt)

        _ = await gate.authorize(ddevConnection(), scopeName: "ddev-shop")
        #expect(prompt.callCount == 1)

        _ = await gate.authorize(ddevConnection(port: 49_154), scopeName: "ddev-blog")
        #expect(prompt.callCount == 2)
    }
}
