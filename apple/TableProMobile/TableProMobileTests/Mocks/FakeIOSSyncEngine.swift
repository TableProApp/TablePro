import Foundation
import os
@testable import TableProMobile
import TableProFFI

// The core engine as the iOS coordinator drives it: what it was asked, and a script for what a pass does.
nonisolated final class FakeIOSSyncEngine: IOSSyncEngine, @unchecked Sendable {
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

    func icloudAccount() -> String? {
        "_alice"
    }
}
