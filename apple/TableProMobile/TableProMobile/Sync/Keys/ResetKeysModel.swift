import Combine
import Foundation
import Observation
import os
import TableProFFI
import TableProLogRedaction

struct ResetProposalRequest: Identifiable, Equatable {
    let kind: ResetKindTag

    var id: String {
        switch kind {
        case .keepScopeKeys: "keep-scope-keys"
        case .startEmpty: "start-empty"
        }
    }
}

struct ResetCancelRequest: Identifiable, Equatable {
    let reset: PendingResetInfo

    var id: String { reset.reset }
}

struct ResetNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case ended(ResetStateTag)
        // A kind 3 reset a server restore lost, which goes up again only after a fresh step-up (core ADR 0065).
        case waitsForStepUp(reset: String)
    }

    enum Tone: Equatable {
        case info
        case success
        case warning
    }

    let id: String
    let kind: Kind

    var text: String {
        switch kind {
        case .ended(.cancelled): String(localized: "The key reset was cancelled.")
        case .ended(.superseded): String(localized: "The key reset ended without changing your keys.")
        case .ended(.active): String(localized: "Your keys were reset.")
        case .ended(.pending): String(localized: "A key reset is waiting.")
        case .waitsForStepUp: String(localized: "A server restore lost your key reset. Confirm it's you to ask for it again.")
        }
    }

    var tone: Tone {
        switch kind {
        case .ended(.active): .success
        case .ended: .info
        case .waitsForStepUp: .warning
        }
    }
}

// A reset when the recovery key is lost (core ADR 0056, Account flows, Reset): a proposal held 7 days that any device
// certified at the current `av`, or the recovery key, can cancel, then the proposing device's activation.
@MainActor @Observable
final class ResetKeysModel {
    enum Work: Equatable {
        case cancelling
        case activating
        case proposingAgain
        case dismissing(String)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ResetKeys")

    private(set) var keyState: KeyStateInfo?
    private(set) var pending: PendingResetInfo?
    private(set) var notices: [ResetNotice] = []
    private(set) var isLoading = false
    private(set) var loadFailure: String?
    private(set) var work: Work?
    var proposal: ResetProposalRequest?
    var cancelsWithRecoveryKey: ResetCancelRequest?
    var pendingActivation: PendingResetInfo?
    var pendingCancel: PendingResetInfo?
    var failure: AccountActionFailure?

    @ObservationIgnored let service: any ResetKeysService
    @ObservationIgnored let stepUp: StepUpRetry
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var observers: Set<AnyCancellable> = []
    @ObservationIgnored private var generation = 0
    // Bumped when the account signs in or out, so what an operation for the old one answers lands nowhere.
    @ObservationIgnored private var account = 0

    init(
        service: any ResetKeysService,
        stepUp: StepUpRetry,
        changes: AnyPublisher<Void, Never>,
        accountChanges: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.service = service
        self.stepUp = stepUp
        self.now = now
        changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.load() }
            }
            .store(in: &observers)
        accountChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.forgetAccount()
                    await self?.load()
                }
            }
            .store(in: &observers)
    }

    // Over the keys page's service and step-up.
    convenience init(environment: AccountKeysEnvironment) {
        self.init(
            service: environment.resets,
            stepUp: environment.stepUp,
            changes: environment.keyChanges,
            accountChanges: environment.accountChanges,
            now: environment.now
        )
    }

    // Another account's reset, notices and open questions never show under the next one, even when its first read fails.
    private func forgetAccount() {
        account += 1
        generation += 1
        keyState = nil
        pending = nil
        notices = []
        isLoading = false
        loadFailure = nil
        proposal = nil
        cancelsWithRecoveryKey = nil
        pendingActivation = nil
        pendingCancel = nil
        failure = nil
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

    nonisolated static func date(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(microseconds) / 1_000_000)
    }

    // A step-up the person closed says nothing; any other failure is worded.
    nonisolated static func failureMessage(_ error: any Error) -> String? {
        if let stepUp = StepUpRetry.failure(error) {
            switch stepUp {
            case .canceled: return nil
            case .failed(let message): return message
            }
        }
        return AccountKeysText.message(for: error)
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
            AccountKeysText.log(error, while: "Reading the key reset")
            loadFailure = Self.failureMessage(error)
        }
        do {
            let notices = try await service.keyNotices()
            guard current == generation else { return }
            self.notices = notices.compactMap { notice -> ResetNotice? in
                switch notice.kind {
                case .resetEnded(_, let state): ResetNotice(id: notice.id, kind: .ended(state))
                case .resetWaitsForStepUp(let reset): ResetNotice(id: notice.id, kind: .waitsForStepUp(reset: reset))
                default: nil
                }
            }
        } catch {
            Self.logger.error("Could not read the key notices: \(LogRedaction.publicDescription(of: error), privacy: .public)")
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

    func proposeAgain(_ reset: String) async {
        await perform(.proposingAgain, failureTitle: String(localized: "Couldn't Ask for the Reset Again")) { [service, stepUp] in
            try await stepUp.run { try await service.proposeResetAgain(reset: reset) }
        }
    }

    func dismiss(_ notice: ResetNotice) async {
        await perform(.dismissing(notice.id), failureTitle: String(localized: "Couldn't Dismiss the Notice")) { [service] in
            try await service.dismissKeyNotice(notice: notice.id)
        }
    }

    @discardableResult
    private func perform(_ work: Work, failureTitle: String, _ call: @escaping @MainActor () async throws -> Void) async -> Bool {
        guard self.work == nil else { return false }
        self.work = work
        defer { self.work = nil }
        let started = account
        var succeeded = false
        do {
            try await call()
            succeeded = true
        } catch {
            AccountKeysText.log(error, while: failureTitle)
            if started == account, let message = Self.failureMessage(error) {
                failure = AccountActionFailure(title: failureTitle, message: message)
            }
        }
        guard started == account else { return false }
        await load()
        return succeeded
    }
}

// One proposal: R' shown once, two of its groups typed back, then the `key.reset` (core ADR 0056, The recovery key).
// A kind 3 proposal needs a fresh step-up, which the account runs once when the server asks for it.
@MainActor @Observable
final class ResetProposalModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ResetKeys")

    enum Phase: Equatable {
        case explain
        case preparing
        case showKey
        case typeBack
        case submitting
        case done
    }

    let kind: ResetKindTag
    private(set) var phase: Phase = .explain
    var typed = ["", ""]
    private(set) var failure: String?
    private(set) var proposed: PendingResetInfo?
    private(set) var groups: [String] = []
    // The two groups to type back, counted from 1 as the person reads them.
    private(set) var checkedGroups: [Int] = []
    @ObservationIgnored private var draft: RecoveryKeyDraftInfo?
    // Set when the sheet closes, so a draft that arrives after that is discarded as it lands.
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private let service: any ResetKeysService
    @ObservationIgnored private let stepUp: StepUpRetry

    init(kind: ResetKindTag, service: any ResetKeysService, stepUp: StepUpRetry) {
        self.kind = kind
        self.service = service
        self.stepUp = stepUp
    }

    var keyText: String {
        groups.joined(separator: "-")
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
            let made = try await stepUp.run { try await service.beginReset(kind: kind) }
            guard !isClosed else {
                await discard(made)
                return
            }
            draft = made
            // R is 14 groups of 4 joined by `-` (core ADR 0056, The recovery key).
            groups = made.text.split(separator: "-").map(String.init)
            checkedGroups = made.check.map { Int($0) + 1 }
            phase = .showKey
        } catch {
            AccountKeysText.log(error, while: "Starting a key reset")
            failure = ResetKeysModel.failureMessage(error)
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

    // The sheet closed before the proposal went up, so the core drops the draft and the recovery key it holds.
    func close() async {
        isClosed = true
        guard let draft, phase != .submitting else { return }
        self.draft = nil
        groups = []
        checkedGroups = []
        typed = ["", ""]
        await discard(draft)
    }

    private func discard(_ draft: RecoveryKeyDraftInfo) async {
        do {
            try await service.discardKeyDraft(draft: draft.draft)
        } catch {
            Self.logger.error("Could not discard the reset draft: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
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
            groups = []
            checkedGroups = []
            phase = .done
        } catch {
            AccountKeysText.log(error, while: "Asking for a key reset")
            failure = ResetKeysModel.failureMessage(error)
            phase = .typeBack
        }
    }
}
