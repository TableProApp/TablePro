//
//  ResetKeysService.swift
//  TablePro
//

import Foundation
import TableProFFI

// The reset flows of the core's sync service (core ADR 0056, Account flows, Reset), so the sheets run over a fake.
nonisolated internal protocol ResetKeysService: AnyObject, Sendable {
    func keyState() async throws -> KeyStateInfo
    func pendingReset() async throws -> PendingResetInfo?
    func beginReset(kind: ResetKindTag) async throws -> RecoveryKeyDraftInfo
    func finishResetProposal(draft: String, typed: [String]) async throws -> PendingResetInfo
    // A sheet closed before its proposal went up: the draft goes, and the recovery key it held with it.
    func discardKeyDraft(draft: String) async throws
    func cancelReset(reset: String, recoveryKey: String?) async throws
    // A kind 3 proposal a server restore lost, sent again; the server asks for a fresh step-up first (core ADR 0065).
    func proposeResetAgain(reset: String) async throws
    func activateReset(reset: String) async throws
    func keyNotices() async throws -> [KeyNoticeInfo]
    func dismissKeyNotice(notice: String) async throws
}

internal final class ResetKeysLiveService: ResetKeysService {
    static let shared = ResetKeysLiveService()

    private let service: @Sendable () async throws -> SyncService

    init(service: @escaping @Sendable () async throws -> SyncService = { try await TeamKeysEngine.service() }) {
        self.service = service
    }

    func keyState() async throws -> KeyStateInfo {
        try await service().keyState()
    }

    func pendingReset() async throws -> PendingResetInfo? {
        try await service().pendingReset()
    }

    func beginReset(kind: ResetKindTag) async throws -> RecoveryKeyDraftInfo {
        try await service().beginReset(kind: kind)
    }

    func finishResetProposal(draft: String, typed: [String]) async throws -> PendingResetInfo {
        try await service().finishResetProposal(draft: draft, typed: typed)
    }

    func discardKeyDraft(draft: String) async throws {
        try await service().discardKeyDraft(draft: draft)
    }

    func cancelReset(reset: String, recoveryKey: String?) async throws {
        try await service().cancelReset(reset: reset, recoveryKey: recoveryKey)
    }

    // Lane K8 adds the call that sends the lost proposal again; until then the core holds it with the notice.
    func proposeResetAgain(reset: String) async throws {
        throw TeamKeysCallMissing()
    }

    func activateReset(reset: String) async throws {
        try await service().activateReset(reset: reset)
    }

    func keyNotices() async throws -> [KeyNoticeInfo] {
        try await service().keyNotices()
    }

    func dismissKeyNotice(notice: String) async throws {
        try await service().dismissKeyNotice(notice: notice)
    }
}
