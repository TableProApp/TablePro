//
//  AccountKeyFlows.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI
import TableProHTTP

// What a removal asks the person about (core ADR 0056, Removing a device, step 2): the devices a rotation can keep,
// and the teammates this account confirmed while the lost device held its keys. `record` goes back unchanged.
nonisolated internal struct AccountRemovalReview: Sendable {
    struct Member: Identifiable, Sendable {
        let record: ReviewedMemberInfo

        var id: String { record.team + "/" + record.account }
        // The same `team_` id the profile's memberships and the portal's team pages use.
        var team: String { record.team }
        var teamName: String? { record.teamName }
        var name: String? { record.name }
        var email: String? { record.email }
        // This account's own row, which the review lists but never removes.
        var isSelf: Bool { record.isSelf }
    }

    let review: String
    let devices: [ReviewedDeviceInfo]
    let members: [Member]

    init(_ info: RemovalReviewInfo) {
        review = info.review
        devices = info.devices
        members = info.members.map(Member.init)
    }
}

// The key-flow calls the account's end-to-end screens make (core ADR 0056, Approving a device and Account flows), so
// their models run over a fake in tests. `SyncService` answers them.
nonisolated internal protocol AccountKeyFlows: AnyObject, Sendable {
    func keyState() async throws -> KeyStateInfo
    func beginGenesis() async throws -> RecoveryKeyDraftInfo
    func finishGenesis(draft: String, typed: [String]) async throws -> GenesisOutcomeTag
    func signOutKeys() async throws -> SignOutOutcomeTag
    func beginReplaceRecoveryKey(recoveryKey: String) async throws -> RotationDraftInfo
    func finishReplaceRecoveryKey(draft: String, typed: [String], keep: [String]) async throws
    func recoverWithRecoveryKey(recoveryKey: String) async throws
    // A Set Up, Replace or Remove draft the person left: the core drops it and the recovery key a replace held.
    func discardKeyDraft(draft: String) throws

    func requestApproval() async throws -> String
    func approvalRequests() async throws -> [ApprovalRequestInfo]
    func chooseApprovalRequest(request: String) async throws -> ApprovalSessionInfo
    func approvalSession(request: String) async throws -> ApprovalSessionInfo
    func confirmApprovalSession(request: String) async throws -> ApprovalSessionInfo
    func approvalWordsDiffer(request: String) async throws
    func cancelApprovalSession(request: String) async throws

    func accountDevices() async throws -> [AccountDeviceInfo]
    func removeDeviceRow(device: String) async throws
    func beginDeviceRemoval(recoveryKey: String, lost: [String]) async throws -> RemovalReviewInfo
    func finishDeviceRemoval(review: String, keep: [String], remove: [ReviewedMemberInfo]) async throws
}

extension SyncService: AccountKeyFlows {}

// Where the end-to-end screens reach the core and the account.
@MainActor
internal struct AccountKeysEnvironment {
    var flows: @MainActor () async throws -> any AccountKeyFlows
    // The core's listener: the key state, a session or the devices changed.
    var keyChanges: AnyPublisher<Void, Never>
    // A sign-in or a sign-out: what was read belongs to the account before it.
    var accountChanges: AnyPublisher<Void, Never>
    var stepUp: StepUpRetry
    var resets: any ResetKeysService
    var portal: @MainActor () -> AccountPortal
    var openURL: @MainActor (URL) -> Void
    var copySecret: @MainActor (String) -> Void
    var clock: any Clock<Duration>
    var now: @MainActor () -> Date

    static func liveFlows() async throws -> any AccountKeyFlows {
        try await SyncEngineHost.shared.keyService()
    }

    static var live: AccountKeysEnvironment {
        AccountKeysEnvironment(
            flows: liveFlows,
            keyChanges: SyncEngineHost.shared.keyChanges.eraseToAnyPublisher(),
            accountChanges: AccountServices.shared.events.map { _ in () }.eraseToAnyPublisher(),
            stepUp: .live,
            resets: ResetKeysLiveService.shared,
            portal: { AccountServices.shared.portal },
            openURL: { _ = WebPageOpener.open($0, scope: .httpsOrLoopbackHTTP) },
            copySecret: { ClipboardService.shared.writeSecretText($0) },
            clock: ContinuousClock(),
            now: { Date() }
        )
    }
}
