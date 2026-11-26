//
//  AccountKeyFlows.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI

// What a removal asks the person about (core ADR 0056, Removing a device, step 2): the devices a rotation can keep,
// and the teammates this account confirmed while the lost device held its keys. `record` goes back unchanged.
nonisolated internal struct AccountRemovalReview: Sendable {
    struct Member: Identifiable, Sendable {
        let record: ReviewedMemberInfo
        let teamID: String?
        let teamName: String?
        let name: String?
        let email: String?

        var id: String { record.team + "/" + record.account }
        var team: String { record.team }
    }

    let review: String
    let devices: [ReviewedDeviceInfo]
    let members: [Member]
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

    func requestApproval() async throws -> String
    func approvalRequests() async throws -> [ApprovalRequestInfo]
    func chooseApprovalRequest(request: String) async throws -> ApprovalSessionInfo
    func approvalSession(request: String) async throws -> ApprovalSessionInfo
    func confirmApprovalSession(request: String) async throws -> ApprovalSessionInfo
    func approvalWordsDiffer(request: String) async throws
    func cancelApprovalSession(request: String) async throws

    func accountDevices() async throws -> [AccountDeviceInfo]
    func removeDeviceRow(device: String) async throws
    func reviewDeviceRemoval(recoveryKey: String, lost: [String]) async throws -> AccountRemovalReview
    func finishDeviceRemoval(review: String, keep: [String], remove: [ReviewedMemberInfo]) async throws
}

extension SyncService: AccountKeyFlows {
    // K8 adds the team's id and name and the member's name and email to `ReviewedMemberInfo`.
    func reviewDeviceRemoval(recoveryKey: String, lost: [String]) async throws -> AccountRemovalReview {
        let review = try await beginDeviceRemoval(recoveryKey: recoveryKey, lost: lost)
        return AccountRemovalReview(
            review: review.review,
            devices: review.devices,
            members: review.members.map {
                AccountRemovalReview.Member(record: $0, teamID: nil, teamName: nil, name: nil, email: nil)
            }
        )
    }
}

// Where the end-to-end screens reach the core and the account.
@MainActor
internal struct AccountKeysEnvironment {
    var flows: @MainActor () async throws -> any AccountKeyFlows
    // The core's listener: the key state, a session or the devices changed.
    var keyChanges: AnyPublisher<Void, Never>
    var stepUp: StepUpRetry
    var portal: @MainActor () -> AccountPortal
    var openURL: @MainActor (URL) -> Void
    var copySecret: @MainActor (String) -> Void
    var clock: any Clock<Duration>
    var now: @MainActor () -> Date

    // The app's one sync service, opened on first use.
    static func liveFlows() async throws -> any AccountKeyFlows {
        guard let flows = try await SyncEngineHost.shared.engine() as? any AccountKeyFlows else {
            throw AccountError.invalidResponse
        }
        return flows
    }

    static var live: AccountKeysEnvironment {
        AccountKeysEnvironment(
            flows: liveFlows,
            keyChanges: SyncEngineHost.shared.keyChanges.eraseToAnyPublisher(),
            stepUp: .live,
            portal: { AccountServices.shared.portal },
            openURL: { _ = WebPageOpener.open($0, scope: .httpsOrLoopbackHTTP) },
            copySecret: { ClipboardService.shared.writeSecretText($0) },
            clock: ContinuousClock(),
            now: { Date() }
        )
    }
}
