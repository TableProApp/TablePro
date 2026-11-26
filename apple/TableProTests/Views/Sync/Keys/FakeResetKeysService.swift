//
//  FakeResetKeysService.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProFFI

enum ResetKeysFixtures {
    static let recoveryKey = "0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ-0123-4567-89AB-CDEF-GHJK-MNPQ"

    static let held = Date(timeIntervalSince1970: 1_800_000_000)

    static func draft(check: [UInt8] = [2, 11]) -> RecoveryKeyDraftInfo {
        RecoveryKeyDraftInfo(draft: "draft-1", text: recoveryKey, check: Data(check))
    }

    static func pending(
        kind: ResetKindTag = .keepScopeKeys,
        state: ResetStateTag = .pending,
        mine: Bool = true,
        proposedBy: String? = nil
    ) -> PendingResetInfo {
        PendingResetInfo(
            reset: "reset-1",
            kind: kind,
            state: state,
            mine: mine,
            proposedBy: proposedBy,
            takenAtUs: Int64(held.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 * 1_000_000),
            heldUntilUs: Int64(held.timeIntervalSince1970 * 1_000_000)
        )
    }
}

final class FakeResetKeysService: ResetKeysService, @unchecked Sendable {
    enum Call: Equatable {
        case begin(ResetKindTag)
        case finish(draft: String, typed: [String])
        case cancel(reset: String, recoveryKey: String?)
        case activate(reset: String)
        case dismiss(notice: String)
    }

    struct State {
        var keyState: KeyStateInfo = .approved(av: 2, keyDevice: "kd-1")
        var pending: PendingResetInfo?
        var notices: [KeyNoticeInfo] = []
        var draft = ResetKeysFixtures.draft()
        // Each call name's failures, thrown one per call until none is left.
        var failures: [String: [CoreError]] = [:]
        var calls: [Call] = []
    }

    let state = OSAllocatedUnfairLock(uncheckedState: State())

    func update(_ change: (inout State) -> Void) {
        state.withLockUnchecked { change(&$0) }
    }

    func read<Value>(_ value: (State) -> Value) -> Value {
        state.withLockUnchecked { value($0) }
    }

    var calls: [Call] { read(\.calls) }

    private func answer<Value>(_ name: String, call: Call? = nil, _ value: (inout State) -> Value) throws -> Value {
        try state.withLockUnchecked { state in
            if let call { state.calls.append(call) }
            if var queued = state.failures[name], !queued.isEmpty {
                let failure = queued.removeFirst()
                state.failures[name] = queued
                throw failure
            }
            return value(&state)
        }
    }

    func keyState() async throws -> KeyStateInfo {
        try answer("keyState") { $0.keyState }
    }

    func pendingReset() async throws -> PendingResetInfo? {
        try answer("pendingReset") { $0.pending }
    }

    func beginReset(kind: ResetKindTag) async throws -> RecoveryKeyDraftInfo {
        try answer("beginReset", call: .begin(kind)) { $0.draft }
    }

    func finishResetProposal(draft: String, typed: [String]) async throws -> PendingResetInfo {
        try answer("finishResetProposal", call: .finish(draft: draft, typed: typed)) { state in
            let pending = ResetKeysFixtures.pending()
            state.pending = pending
            return pending
        }
    }

    func cancelReset(reset: String, recoveryKey: String?) async throws {
        try answer("cancelReset", call: .cancel(reset: reset, recoveryKey: recoveryKey)) { $0.pending = nil }
    }

    func activateReset(reset: String) async throws {
        try answer("activateReset", call: .activate(reset: reset)) { $0.pending = nil }
    }

    func keyNotices() async throws -> [KeyNoticeInfo] {
        try answer("keyNotices") { $0.notices }
    }

    func dismissKeyNotice(notice: String) async throws {
        try answer("dismissKeyNotice", call: .dismiss(notice: notice)) { state in
            state.notices.removeAll { $0.id == notice }
        }
    }
}
