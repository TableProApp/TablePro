//
//  AIConnectionAccessGateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
private final class PolicyBox {
    var policy: AIConnectionPolicy?

    init(_ policy: AIConnectionPolicy?) {
        self.policy = policy
    }
}

@MainActor
internal struct AIConnectionAccessGateTests {
    private func makeGate(_ box: PolicyBox, approvals: AIAccessApprovals) -> AIConnectionAccessGate {
        AIConnectionAccessGate(approvals: approvals) { _ in box.policy }
    }

    @Test("Always Allow lets a request through without an approval")
    func alwaysAllowIsAllowed() {
        let gate = makeGate(PolicyBox(.alwaysAllow), approvals: AIAccessApprovals())

        #expect(gate.allowsUnpromptedAccess(to: UUID()))
    }

    @Test("Never refuses a request even for a connection the chat approved")
    func neverIsRefusedEvenWhenApproved() {
        let approvals = AIAccessApprovals()
        let connectionId = UUID()
        approvals.approve(connectionId)
        let gate = makeGate(PolicyBox(.never), approvals: approvals)

        #expect(!gate.allowsUnpromptedAccess(to: connectionId))
    }

    @Test("Ask Each Time refuses until the connection is approved, and again once the approval is revoked")
    func askEachTimeFollowsTheApproval() {
        let approvals = AIAccessApprovals()
        let connectionId = UUID()
        let gate = makeGate(PolicyBox(.askEachTime), approvals: approvals)

        #expect(!gate.allowsUnpromptedAccess(to: connectionId))

        approvals.approve(connectionId)
        #expect(gate.allowsUnpromptedAccess(to: connectionId))

        approvals.revoke(connectionId)
        #expect(!gate.allowsUnpromptedAccess(to: connectionId))
    }

    @Test("An approval covers only the connection it was given for")
    func approvalIsPerConnection() {
        let approvals = AIAccessApprovals()
        let approved = UUID()
        approvals.approve(approved)
        let gate = makeGate(PolicyBox(.askEachTime), approvals: approvals)

        #expect(gate.allowsUnpromptedAccess(to: approved))
        #expect(!gate.allowsUnpromptedAccess(to: UUID()))
    }

    @Test("A policy changed after the gate was built is read on the next request")
    func policyIsReadAtEachRequest() {
        let box = PolicyBox(.alwaysAllow)
        let gate = makeGate(box, approvals: AIAccessApprovals())
        let connectionId = UUID()

        #expect(gate.allowsUnpromptedAccess(to: connectionId))

        box.policy = .never
        #expect(!gate.allowsUnpromptedAccess(to: connectionId))
    }

    @Test("An editor with no connection, or a connection nothing knows, is refused")
    func unknownConnectionIsRefused() {
        let approvals = AIAccessApprovals()
        let connectionId = UUID()
        approvals.approve(connectionId)

        #expect(!makeGate(PolicyBox(.alwaysAllow), approvals: approvals).allowsUnpromptedAccess(to: nil))
        #expect(!makeGate(PolicyBox(nil), approvals: approvals).allowsUnpromptedAccess(to: connectionId))
    }
}

@MainActor
internal struct AIConnectionAccessGateSavedPolicyTests {
    private let storage: ConnectionStorage

    init() {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("connections_\(unique).json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let defaults = UserDefaults(suiteName: "com.TablePro.tests.AIAccessGate.\(unique)"),
              let syncDefaults = UserDefaults(suiteName: "com.TablePro.tests.AIAccessGate.Sync.\(unique)")
        else {
            fatalError("Failed to create isolated test user defaults")
        }
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncDefaults))
        self.storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncTracker: tracker,
            keychain: InMemoryKeychain()
        )
    }

    private func makeConnection(id: UUID, policy: AIConnectionPolicy?) -> DatabaseConnection {
        DatabaseConnection(id: id, name: "Inline Access", database: "shop", type: .mysql, aiPolicy: policy)
    }

    private func makeGate(
        manager: DatabaseManager,
        defaultPolicy: @escaping @MainActor () -> AIConnectionPolicy = { .askEachTime }
    ) -> AIConnectionAccessGate {
        AIConnectionAccessGate.savedPolicy(
            connectionStorage: storage,
            databaseManager: manager,
            approvals: AIAccessApprovals(),
            defaultPolicy: defaultPolicy
        )
    }

    @Test("A policy edited in the connection form takes effect on the next request")
    func savedEditTakesEffect() {
        let id = UUID()
        storage.addConnection(makeConnection(id: id, policy: .alwaysAllow))
        let gate = makeGate(manager: DatabaseManager(connectionStorage: storage))

        #expect(gate.allowsUnpromptedAccess(to: id))

        storage.updateConnection(makeConnection(id: id, policy: .never))
        #expect(!gate.allowsUnpromptedAccess(to: id))
    }

    @Test("The saved policy wins over the copy a live session took when it connected")
    func savedPolicyWinsOverSessionCopy() {
        let id = UUID()
        storage.addConnection(makeConnection(id: id, policy: .never))
        let manager = DatabaseManager(connectionStorage: storage)
        manager.injectSession(ConnectionSession(connection: makeConnection(id: id, policy: .alwaysAllow)), for: id)
        defer { manager.removeSession(for: id) }

        #expect(!makeGate(manager: manager).allowsUnpromptedAccess(to: id))
    }

    @Test("Use Default follows the app-wide default as it is when the request is made")
    func useDefaultFollowsTheCurrentDefault() {
        let id = UUID()
        storage.addConnection(makeConnection(id: id, policy: nil))
        let box = PolicyBox(.alwaysAllow)
        let gate = makeGate(manager: DatabaseManager(connectionStorage: storage)) { box.policy ?? .never }

        #expect(gate.allowsUnpromptedAccess(to: id))

        box.policy = .never
        #expect(!gate.allowsUnpromptedAccess(to: id))
    }

    @Test("A live session with no saved record answers with its own policy")
    func unsavedSessionUsesItsOwnPolicy() {
        let allowed = UUID()
        let refused = UUID()
        let manager = DatabaseManager(connectionStorage: storage)
        manager.injectSession(ConnectionSession(connection: makeConnection(id: allowed, policy: .alwaysAllow)), for: allowed)
        manager.injectSession(ConnectionSession(connection: makeConnection(id: refused, policy: .never)), for: refused)
        defer {
            manager.removeSession(for: allowed)
            manager.removeSession(for: refused)
        }
        let gate = makeGate(manager: manager)

        #expect(gate.allowsUnpromptedAccess(to: allowed))
        #expect(!gate.allowsUnpromptedAccess(to: refused))
    }

    @Test("A connection with neither a saved record nor a session is refused")
    func missingConnectionIsRefused() {
        let gate = makeGate(manager: DatabaseManager(connectionStorage: storage)) { .alwaysAllow }

        #expect(!gate.allowsUnpromptedAccess(to: UUID()))
    }
}

@MainActor
internal struct AIAccessApprovalsSessionTests {
    @Test("Ending a connection's session revokes its approval and leaves the others")
    func sessionEndRevokesApproval() {
        let approvals = AIAccessApprovals()
        let manager = DatabaseManager(aiAccessApprovals: approvals)
        let ended = UUID()
        let other = UUID()
        manager.injectSession(ConnectionSession(connection: TestFixtures.makeConnection(id: ended)), for: ended)
        approvals.approve(ended)
        approvals.approve(other)

        manager.removeSession(for: ended)

        #expect(!approvals.isApproved(ended))
        #expect(approvals.isApproved(other))
    }

    @Test("Allow in the chat approves the connection app-wide")
    func chatAllowApprovesAppWide() {
        let connection = DatabaseConnection(name: "Chat Allow", type: .mysql, aiPolicy: .askEachTime)
        defer { AIAccessApprovals.shared.revoke(connection.id) }
        let vm = AIChatViewModel()
        vm.connection = connection

        vm.confirmAIAccess()

        #expect(AIAccessApprovals.shared.isApproved(connection.id))
    }

    @Test("Don't Allow in the chat approves nothing")
    func chatDenyApprovesNothing() {
        let connection = DatabaseConnection(name: "Chat Deny", type: .mysql, aiPolicy: .askEachTime)
        let vm = AIChatViewModel()
        vm.connection = connection
        vm.messages.append(ChatTurn(role: .user, blocks: [.text("Hello")]))
        vm.streamingState = .awaitingApproval

        vm.denyAIAccess()

        #expect(!AIAccessApprovals.shared.isApproved(connection.id))
    }

    @Test("A chat reads an approval another chat gave, and asks again once it is revoked")
    func chatReadsTheSharedApproval() {
        let connection = DatabaseConnection(name: "Chat Shared", type: .mysql, aiPolicy: .askEachTime)
        defer { AIAccessApprovals.shared.revoke(connection.id) }
        let vm = AIChatViewModel()
        vm.connection = connection
        let settings = AISettings()

        #expect(vm.resolveConnectionPolicy(settings: settings) == .askEachTime)

        AIAccessApprovals.shared.approve(connection.id)
        #expect(vm.resolveConnectionPolicy(settings: settings) == .alwaysAllow)

        AIAccessApprovals.shared.revoke(connection.id)
        #expect(vm.resolveConnectionPolicy(settings: settings) == .askEachTime)
    }

    @Test("An approval never lifts Never in the chat")
    func chatNeverIgnoresApproval() {
        let connection = DatabaseConnection(name: "Chat Never", type: .mysql, aiPolicy: .never)
        defer { AIAccessApprovals.shared.revoke(connection.id) }
        let vm = AIChatViewModel()
        vm.connection = connection
        AIAccessApprovals.shared.approve(connection.id)

        #expect(vm.resolveConnectionPolicy(settings: AISettings()) == .never)
    }
}
