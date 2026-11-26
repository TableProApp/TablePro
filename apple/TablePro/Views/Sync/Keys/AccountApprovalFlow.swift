//
//  AccountApprovalFlow.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI

// One approval session as either side sees it (core ADR 0056, Approving a device): the new Mac asking, or an
// approved Mac answering a request it picked. The sheet polls the session every 1.5 s while it is open, as the ADR asks
// of both devices, and the five words live only in this object.
@MainActor
internal final class AccountApprovalFlow: ObservableObject, Identifiable {
    enum Role: Equatable {
        case newDevice
        // The request the person picked, shown before this Mac commits to it with its `nonce` step.
        case approver(ApprovalRequestInfo)
    }

    enum Phase: Equatable {
        case reviewing
        case starting
        case waiting
        case chosen
        case compare(words: [String])
        case confirmed
        case approved
        case takenElsewhere
        case cancelled(SessionEndTag)
        case expired
        case failed(String)

        var hasEnded: Bool {
            switch self {
            case .approved, .takenElsewhere, .cancelled, .expired, .failed: true
            case .reviewing, .starting, .waiting, .chosen, .compare, .confirmed: false
            }
        }
    }

    static let pollInterval: Duration = .milliseconds(1_500)

    let id = UUID()
    let role: Role
    @Published private(set) var phase: Phase {
        didSet {
            if phase.hasEnded {
                polling?.cancel()
                polling = nil
            }
        }
    }
    @Published private(set) var expiresAt: Date?
    @Published private(set) var isWorking = false
    @Published private(set) var actionFailure: String?

    private let flows: @MainActor () async throws -> any AccountKeyFlows
    private let clock: any Clock<Duration>
    private(set) var request: String?
    private var polling: Task<Void, Never>?
    private var started = false
    // Closed while a call was out: what it answers is dropped.
    private var closed = false

    init(
        role: Role,
        request: String? = nil,
        flows: @escaping @MainActor () async throws -> any AccountKeyFlows,
        clock: any Clock<Duration>
    ) {
        self.role = role
        self.request = request
        self.flows = flows
        self.clock = clock
        switch role {
        case .newDevice: phase = .starting
        case .approver: phase = .reviewing
        }
    }

    var isNewDevice: Bool {
        role == .newDevice
    }

    // The new Mac writes its request, or picks up the one it already has open.
    func start() async {
        guard case .newDevice = role, !started, !closed else { return }
        started = true
        do {
            let flows = try await flows()
            let request: String
            if let open = self.request {
                request = open
            } else {
                request = try await flows.requestApproval()
            }
            guard !closed else {
                cancelSession(request)
                return
            }
            self.request = request
            let session = try await flows.approvalSession(request: request)
            guard !closed else { return }
            apply(session)
            startPolling()
        } catch {
            guard !closed else { return }
            phase = .failed(AccountKeysText.message(for: error))
        }
    }

    // The approver commits to the request: the first `nonce` step holds the session.
    func approve() async {
        guard case .approver(let info) = role, phase == .reviewing else { return }
        phase = .starting
        request = info.request
        do {
            let session = try await flows().chooseApprovalRequest(request: info.request)
            guard !closed else { return }
            apply(session)
            startPolling()
        } catch {
            guard !closed else { return }
            phase = .failed(AccountKeysText.message(for: error))
        }
    }

    func wordsMatch() async {
        guard case .compare = phase, let request else { return }
        await act { flows in
            self.apply(try await flows.confirmApprovalSession(request: request))
        }
    }

    func wordsDiffer() async {
        guard case .compare = phase, let request else { return }
        await act { flows in
            try await flows.approvalWordsDiffer(request: request)
            self.phase = .cancelled(.mismatch)
        }
    }

    // The sheet closed. A session still running is cancelled with `user`, so the other side stops too.
    func close() {
        closed = true
        polling?.cancel()
        polling = nil
        let wasRunning = !phase.hasEnded && phase != .reviewing
        guard wasRunning, let request else { return }
        phase = .cancelled(.user)
        cancelSession(request)
    }

    private func cancelSession(_ request: String) {
        let flows = flows
        Task {
            try? await flows().cancelApprovalSession(request: request)
        }
    }

    func refresh() async {
        guard let request, !phase.hasEnded else { return }
        do {
            apply(try await flows().approvalSession(request: request))
        } catch {
            actionFailure = AccountKeysText.message(for: error)
        }
    }

    private func startPolling() {
        guard polling == nil, !phase.hasEnded else { return }
        polling = Task { [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.pollInterval)
                } catch {
                    return
                }
                guard let self, !self.phase.hasEnded else { return }
                await self.refresh()
            }
        }
    }

    private func apply(_ session: ApprovalSessionInfo) {
        expiresAt = AccountKeysText.date(microseconds: session.expiresAtUs)
        actionFailure = nil
        switch session.phase {
        case .open:
            phase = .waiting
        case .chosen:
            phase = .chosen
        case .compare(let words):
            phase = .compare(words: words)
        case .confirmed:
            // A confirmed side keeps no words on screen.
            phase = .confirmed
        case .approved:
            phase = .approved
        case .takenElsewhere:
            phase = .takenElsewhere
        case .cancelled(let reason):
            phase = .cancelled(reason)
        case .expired:
            phase = .expired
        }
    }

    private func act(_ body: @MainActor (any AccountKeyFlows) async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await body(try await flows())
        } catch {
            actionFailure = AccountKeysText.message(for: error)
        }
    }
}
