//
//  ResetKeysModel.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProFFI

internal struct ResetProposalRequest: Identifiable, Equatable {
    let kind: ResetKindTag

    var id: String {
        switch kind {
        case .keepScopeKeys: "keep-scope-keys"
        case .startEmpty: "start-empty"
        }
    }
}

internal struct ResetCancelRequest: Identifiable, Equatable {
    let reset: PendingResetInfo

    var id: String { reset.reset }
}

internal struct ResetEndedNotice: Identifiable, Equatable {
    let id: String
    let state: ResetStateTag

    var text: String {
        switch state {
        case .cancelled: String(localized: "The key reset was cancelled.")
        case .superseded: String(localized: "The key reset ended without changing your keys.")
        case .active: String(localized: "Your keys were reset.")
        case .pending: String(localized: "A key reset is waiting.")
        }
    }
}

// A reset when the recovery key is lost (core ADR 0056, Account flows, Reset): a proposal held 7 days that any device
// certified at the current `av`, or the recovery key, can cancel, then the proposing device's activation.
@MainActor
internal final class ResetKeysModel: ObservableObject {
    enum Work: Equatable {
        case cancelling
        case activating
        case dismissing(String)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ResetKeys")

    @Published private(set) var keyState: KeyStateInfo?
    @Published private(set) var pending: PendingResetInfo?
    @Published private(set) var endedNotices: [ResetEndedNotice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailure: String?
    @Published private(set) var work: Work?
    @Published var proposal: ResetProposalRequest?
    @Published var cancelsWithRecoveryKey: ResetCancelRequest?
    @Published var pendingActivation: PendingResetInfo?
    @Published var pendingCancel: PendingResetInfo?
    @Published var failure: AccountActionFailure?

    let service: any ResetKeysService
    let stepUp: StepUpRetry
    private let now: () -> Date
    private var changeObserver: AnyCancellable?
    private var generation = 0

    init(
        service: any ResetKeysService,
        stepUp: StepUpRetry,
        changes: AnyPublisher<Void, Never>,
        now: @escaping () -> Date = { Date() }
    ) {
        self.service = service
        self.stepUp = stepUp
        self.now = now
        changeObserver = changes.sink { [weak self] _ in
            guard let self else { return }
            Task { await self.load() }
        }
    }

    convenience init() {
        self.init(
            service: ResetKeysLiveService.shared,
            stepUp: .live,
            changes: SyncEngineHost.shared.keyChanges.eraseToAnyPublisher()
        )
    }

    // Kind 2 keeps the scope keys and starts from an approved device; kind 3 starts empty from a sign-in whose device is
    // not approved, a locked one included.
    var offeredKind: ResetKindTag? {
        switch keyState {
        case .approved: .keepScopeKeys
        case .needsApproval, .locked: .startEmpty
        case .noDeviceStore, .unknown, .noKeys, nil: nil
        }
    }

    // Only a device certified at the current `av` cancels without the recovery key.
    var cancelsWithoutRecoveryKey: Bool {
        if case .approved = keyState { return true }
        return false
    }

    func canActivate(_ reset: PendingResetInfo) -> Bool {
        reset.mine && reset.state == .pending && now() >= Self.date(reset.heldUntilUs)
    }

    static func date(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(microseconds) / 1_000_000)
    }

    func load() async {
        generation += 1
        let current = generation
        isLoading = true
        defer {
            if current == generation { isLoading = false }
        }
        do {
            let state = try await service.keyState()
            let reset = try await service.pendingReset()
            guard current == generation else { return }
            keyState = state
            pending = reset?.state == .pending ? reset : nil
            loadFailure = nil
        } catch {
            guard current == generation else { return }
            loadFailure = TeamKeysFailureText.message(error)
        }
        do {
            let notices = try await service.keyNotices()
            guard current == generation else { return }
            endedNotices = notices.compactMap { notice -> ResetEndedNotice? in
                guard case .resetEnded(_, let state) = notice.kind else { return nil }
                return ResetEndedNotice(id: notice.id, state: state)
            }
        } catch {
            Self.logger.error("Could not read the key notices: \(error.publicLogShape, privacy: .public)")
        }
    }

    func cancel(_ reset: PendingResetInfo) async {
        await perform(.cancelling, failureTitle: String(localized: "Couldn't Cancel the Reset")) { [service] in
            try await service.cancelReset(reset: reset.reset, recoveryKey: nil)
        }
    }

    @discardableResult
    func cancel(_ reset: PendingResetInfo, recoveryKey: String) async -> Bool {
        await perform(.cancelling, failureTitle: String(localized: "Couldn't Cancel the Reset")) { [service] in
            try await service.cancelReset(reset: reset.reset, recoveryKey: recoveryKey)
        }
    }

    func activate(_ reset: PendingResetInfo) async {
        await perform(.activating, failureTitle: String(localized: "Couldn't Finish the Reset")) { [service] in
            try await service.activateReset(reset: reset.reset)
        }
    }

    func dismiss(_ notice: ResetEndedNotice) async {
        await perform(.dismissing(notice.id), failureTitle: String(localized: "Couldn't Dismiss the Notice")) { [service] in
            try await service.dismissKeyNotice(notice: notice.id)
        }
    }

    @discardableResult
    private func perform(_ work: Work, failureTitle: String, _ call: @escaping () async throws -> Void) async -> Bool {
        guard self.work == nil else { return false }
        self.work = work
        defer { self.work = nil }
        var succeeded = false
        do {
            try await call()
            succeeded = true
        } catch {
            if let message = TeamKeysFailureText.message(error) {
                failure = AccountActionFailure(title: failureTitle, message: message)
            }
        }
        await load()
        return succeeded
    }
}

// One proposal: R' shown once, two of its groups typed back, then the `key.reset` (core ADR 0056, The recovery key).
// A kind 3 proposal needs a fresh step-up, which the account runs once when the server asks for it.
@MainActor
internal final class ResetProposalModel: ObservableObject {
    enum Phase: Equatable {
        case explain
        case preparing
        case showKey
        case typeBack
        case submitting
        case done
    }

    let kind: ResetKindTag
    @Published private(set) var phase: Phase = .explain
    @Published var typed = ["", ""]
    @Published private(set) var failure: String?
    @Published private(set) var proposed: PendingResetInfo?
    private(set) var draft: RecoveryKeyDraftInfo?
    private let service: any ResetKeysService
    private let stepUp: StepUpRetry

    init(kind: ResetKindTag, service: any ResetKeysService, stepUp: StepUpRetry) {
        self.kind = kind
        self.service = service
        self.stepUp = stepUp
    }

    // R is 14 groups of 4 joined by `-` (core ADR 0056, The recovery key).
    var groups: [String] {
        draft?.text.split(separator: "-").map(String.init) ?? []
    }

    // The two groups to type back, counted from 1 as the person reads them.
    var checkedGroups: [Int] {
        draft.map { $0.check.map { Int($0) + 1 } } ?? []
    }

    var canSubmit: Bool {
        phase == .typeBack && typed.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func begin() async {
        guard phase == .explain else { return }
        phase = .preparing
        failure = nil
        do {
            let kind = kind
            let service = service
            draft = try await stepUp.run { try await service.beginReset(kind: kind) }
            phase = .showKey
        } catch {
            failure = TeamKeysFailureText.message(error)
            phase = .explain
        }
    }

    func continueToTypeBack() {
        guard phase == .showKey else { return }
        typed = ["", ""]
        failure = nil
        phase = .typeBack
    }

    func showKeyAgain() {
        guard phase == .typeBack else { return }
        phase = .showKey
    }

    func submit() async {
        guard canSubmit, let draft else { return }
        phase = .submitting
        failure = nil
        do {
            let service = service
            let typed = typed
            proposed = try await stepUp.run {
                try await service.finishResetProposal(draft: draft.draft, typed: typed)
            }
            self.draft = nil
            phase = .done
        } catch {
            failure = TeamKeysFailureText.message(error)
            phase = .typeBack
        }
    }
}
