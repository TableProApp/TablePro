import Foundation
import os
@testable import TableProMobile
import TableProFFI

// The core engine as the iOS coordinator and the moves drive it: what it was asked, and a script for what a pass does.
nonisolated final class FakeIOSSyncEngine: IOSSyncEngine, SyncMoveEngine, @unchecked Sendable {
    struct State {
        var info = SyncStatusInfo(
            provider: nil,
            phase: .idle,
            lastPassMs: nil,
            problem: nil,
            waitingApprovals: 0,
            conflicts: 0,
            held: 0,
            queuedChanges: 0
        )
        var passes: [PassReasonTag] = []
        var providers: [SyncProviderTag] = []
        var uploadsAgain = 0
        var categories: [SyncCategoriesArg] = []
        var flushes = 0
        var serviceAccount: String?
        var keys: KeyStateInfo = .approved(av: 1, keyDevice: "kd_this")
        var scopes: [ScopeStatusInfo] = []
        var plan = MovePlanInfo(records: 3, stayingBehind: 1, secretsToSeal: 2)
        var movesBack: [UInt64] = []
        var zoneDeletions = 0
        var identityChoices: [NewIdentityChoiceTag] = []
        // Runs inside the move-back plan, as the core's CloudKit reads would.
        var planningBack: (@Sendable () -> Void)?
        var pass: (@Sendable (PassReasonTag) async -> Void)?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func update(_ change: (inout State) -> Void) {
        state.withLockUnchecked { change(&$0) }
    }

    func read<Value>(_ value: (State) -> Value) -> Value {
        state.withLockUnchecked { value($0) }
    }

    func status() -> SyncStatusInfo {
        read { $0.info }
    }

    // Each pass ends at a later time, as the engine stamps the passes it finishes.
    func syncNow(why: PassReasonTag) async throws {
        let pass = state.withLockUnchecked { state in
            state.passes.append(why)
            return state.pass
        }
        await pass?(why)
        update { $0.info.lastPassMs = Int64($0.passes.count) * 1_000 }
    }

    func chooseProvider(provider: SyncProviderTag) async throws {
        update { state in
            state.providers.append(provider)
            state.info.provider = provider
        }
    }

    func uploadAgain() async throws {
        update { $0.uploadsAgain += 1 }
    }

    func setCategories(categories: SyncCategoriesArg) async throws {
        update { $0.categories.append(categories) }
    }

    func icloudAccount() -> String? {
        "_alice"
    }

    func serviceAccount() -> String? {
        read { $0.serviceAccount }
    }

    func flushLegacyMarks() async throws {
        update { $0.flushes += 1 }
    }

    func scopeStatuses() -> [ScopeStatusInfo] {
        read { $0.scopes }
    }

    func keyState() async throws -> KeyStateInfo {
        read { $0.keys }
    }

    func planMoveToService() async throws -> MovePlanInfo {
        read { $0.plan }
    }

    func moveToService() async throws {
        try await chooseProvider(provider: .tableproSync)
    }

    func planMoveToIcloud() async throws -> MoveBackPlanInfo {
        read { $0.planningBack }?()
        return MoveBackPlanInfo(icloudDeletions: 4)
    }

    func moveToIcloud(confirmedDeletions: UInt64) async throws {
        update { state in
            state.movesBack.append(confirmedDeletions)
            state.info.provider = .icloud
        }
    }

    func planNewIdentity() async throws -> NewIdentityPlanInfo {
        NewIdentityPlanInfo(unsent: 2, account: "acct_bob")
    }

    func chooseForNewIdentity(choice: NewIdentityChoiceTag, account: String) async throws {
        update { $0.identityChoices.append(choice) }
    }

    func deleteIcloudZone() async throws {
        update { $0.zoneDeletions += 1 }
    }
}
