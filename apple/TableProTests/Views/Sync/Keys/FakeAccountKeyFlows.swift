//
//  FakeAccountKeyFlows.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport

// The core's key flows as the end-to-end screens reach them: scripted answers, and every call with its arguments.
final class FakeAccountKeyFlows: AccountKeyFlows, @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let arguments: [String]

        init(_ name: String, _ arguments: [String] = []) {
            self.name = name
            self.arguments = arguments
        }
    }

    static let recoveryKey = (1 ... 14).map { String(format: "%04d", $0 * 7) }.joined(separator: "-")

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var failures: [String: [any Error]] = [:]

    var state: KeyStateInfo = .noKeys
    var devices: [AccountDeviceInfo] = []
    var requests: [ApprovalRequestInfo] = []
    // Each read of a session takes the next phase, and the last one stays.
    var sessionPhases: [SessionPhaseTag] = [.open]
    var genesisOutcome = GenesisOutcomeTag.created
    var rotationDevices: [ReviewedDeviceInfo] = []
    var review = AccountRemovalReview(review: "review-1", devices: [], members: [])
    var newRequest = "request-new"
    var expiresAt = Date(timeIntervalSince1970: 2_000_000_000)

    var calls: [Call] {
        locked { recorded }
    }

    func calls(named name: String) -> [Call] {
        calls.filter { $0.name == name }
    }

    // The next call of that name throws it, once per error queued.
    func fail(_ name: String, with error: any Error) {
        locked { failures[name, default: []].append(error) }
    }

    static func failure(_ code: String, sync: SyncFailureInfo? = nil) -> CoreError {
        .Failed(info: ErrorInfo(
            code: code,
            codes: [code],
            message: "",
            server: nil,
            path: nil,
            secret: nil,
            hostKey: nil,
            tlsFailure: nil,
            ai: nil,
            sync: sync,
            stepUp: nil
        ))
    }

    static func device(
        _ keyDevice: String,
        row: String? = nil,
        name: String? = nil,
        thisDevice: Bool = false,
        compared: Bool = false,
        addedAtUs: Int64? = 1_700_000_000_000_000
    ) -> AccountDeviceInfo {
        AccountDeviceInfo(
            keyDevice: keyDevice,
            device: row,
            name: name ?? keyDevice,
            platform: "macos",
            addedAtUs: addedAtUs,
            thisDevice: thisDevice,
            compared: compared
        )
    }

    static func request(_ id: String, name: String = "MacBook Pro") -> ApprovalRequestInfo {
        ApprovalRequestInfo(request: id, device: "row-\(id)", deviceName: name, platform: "macos", requestedAtUs: 1_700_000_000_000_000)
    }

    // MARK: - AccountKeyFlows

    func keyState() async throws -> KeyStateInfo {
        try record("keyState")
        return locked { state }
    }

    func beginGenesis() async throws -> RecoveryKeyDraftInfo {
        try record("beginGenesis")
        return RecoveryKeyDraftInfo(draft: "genesis-1", text: Self.recoveryKey, check: Data([2, 10]))
    }

    func finishGenesis(draft: String, typed: [String]) async throws -> GenesisOutcomeTag {
        try record("finishGenesis", [draft] + typed)
        return locked { genesisOutcome }
    }

    func signOutKeys() async throws -> SignOutOutcomeTag {
        try record("signOutKeys")
        return .revoked
    }

    func beginReplaceRecoveryKey(recoveryKey: String) async throws -> RotationDraftInfo {
        try record("beginReplace", [recoveryKey])
        return RotationDraftInfo(
            recovery: RecoveryKeyDraftInfo(draft: "replace-1", text: Self.recoveryKey, check: Data([0, 13])),
            devices: locked { rotationDevices }
        )
    }

    func finishReplaceRecoveryKey(draft: String, typed: [String], keep: [String]) async throws {
        try record("finishReplace", [draft] + typed + keep)
    }

    func recoverWithRecoveryKey(recoveryKey: String) async throws {
        try record("recover", [recoveryKey])
    }

    func requestApproval() async throws -> String {
        try record("requestApproval")
        return locked { newRequest }
    }

    func approvalRequests() async throws -> [ApprovalRequestInfo] {
        try record("approvalRequests")
        return locked { requests }
    }

    func chooseApprovalRequest(request: String) async throws -> ApprovalSessionInfo {
        try record("chooseApprovalRequest", [request])
        return session(request, role: .approver)
    }

    func approvalSession(request: String) async throws -> ApprovalSessionInfo {
        try record("approvalSession", [request])
        return session(request, role: .newDevice)
    }

    func confirmApprovalSession(request: String) async throws -> ApprovalSessionInfo {
        try record("confirmApprovalSession", [request])
        return session(request, role: .newDevice)
    }

    func approvalWordsDiffer(request: String) async throws {
        try record("approvalWordsDiffer", [request])
    }

    func cancelApprovalSession(request: String) async throws {
        try record("cancelApprovalSession", [request])
    }

    func accountDevices() async throws -> [AccountDeviceInfo] {
        try record("accountDevices")
        return locked { devices }
    }

    func removeDeviceRow(device: String) async throws {
        try record("removeDeviceRow", [device])
    }

    func reviewDeviceRemoval(recoveryKey: String, lost: [String]) async throws -> AccountRemovalReview {
        try record("reviewDeviceRemoval", [recoveryKey] + lost)
        return locked { review }
    }

    func finishDeviceRemoval(review: String, keep: [String], remove: [ReviewedMemberInfo]) async throws {
        try record("finishDeviceRemoval", [review] + keep + remove.map { "\($0.team)/\($0.account)" })
    }

    // MARK: - Private

    private func session(_ request: String, role: SessionRoleTag) -> ApprovalSessionInfo {
        locked {
            let phase = sessionPhases.count > 1 ? sessionPhases.removeFirst() : sessionPhases.first ?? .open
            let expires = Int64(expiresAt.timeIntervalSince1970 * 1_000_000)
            return ApprovalSessionInfo(request: request, role: role, phase: phase, expiresAtUs: expires)
        }
    }

    private func record(_ name: String, _ arguments: [String] = []) throws {
        let failure = locked { () -> (any Error)? in
            recorded.append(Call(name, arguments))
            guard var queued = failures[name], !queued.isEmpty else { return nil }
            let first = queued.removeFirst()
            failures[name] = queued
            return first
        }
        if let failure { throw failure }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension AccountKeysSignOut {
    // For an account test that signs out with no end-to-end keys in play.
    static var untouched: AccountKeysSignOut {
        AccountKeysSignOut(holdsKeys: { false }, signOut: { true })
    }
}

@MainActor
final class AccountKeysFixture {
    let flows = FakeAccountKeyFlows()
    let keyChanges = PassthroughSubject<Void, Never>()
    let accountChanges = PassthroughSubject<Void, Never>()
    let clock = ManualClock()
    var stepUps: [StepUpChallenge] = []
    var stepUpFailure: (any Error)?
    var opened: [URL] = []
    var copied: [String] = []

    lazy var environment = AccountKeysEnvironment(
        flows: { [flows] in flows },
        keyChanges: keyChanges.eraseToAnyPublisher(),
        accountChanges: accountChanges.eraseToAnyPublisher(),
        stepUp: StepUpRetry { [weak self] challenge in
            guard let self else { return }
            stepUps.append(challenge)
            if let stepUpFailure { throw stepUpFailure }
        },
        portal: { AccountPortal(server: .production) },
        openURL: { [weak self] in self?.opened.append($0) },
        copySecret: { [weak self] in self?.copied.append($0) },
        clock: clock,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    func model() -> AccountKeysModel {
        AccountKeysModel(environment: environment)
    }
}
