import Foundation
import Observation
import TableProFFI

// One approval session as either side sees it (core ADR 0056, Approving a device): the new device asking, or an
// approved device answering a request it picked. The sheet polls the session every 1.5 s while it is open, as the ADR
// asks of both devices, and the five words live only in this object.
@MainActor @Observable
final class AccountApprovalFlow: Identifiable {
    enum Role: Equatable {
        case newDevice
        // The request the person picked, shown before this device commits to it with its `nonce` step.
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

    nonisolated static let pollInterval: Duration = .milliseconds(1_500)

    let id = UUID()
    let role: Role
    private(set) var phase: Phase
    private(set) var expiresAt: Date?
    private(set) var isWorking = false
    private(set) var actionFailure: String?

    @ObservationIgnored private let flows: @MainActor () async throws -> any AccountKeyFlows
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private(set) var request: String?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var started = false
    // Closed while a call was out: what it answers is dropped.
    @ObservationIgnored private var closed = false
    // The session ended as the core reported it, apart from what this sheet shows, so a close cancels any other.
    @ObservationIgnored private var settled = false

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

    // The new device writes its request, or picks up the one it already has open.
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
            AccountKeysText.log(error, while: "The approval request")
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
            AccountKeysText.log(error, while: "Choosing an approval request")
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
            self.settled = true
            self.phase = .cancelled(.mismatch)
            self.stopPollingIfEnded()
        }
    }

    // The sheet closed. A session still running is cancelled with `user`, so the other side stops too.
    func close() {
        guard !closed else { return }
        closed = true
        polling?.cancel()
        polling = nil
        guard let request, !settled else { return }
        settled = true
        if !phase.hasEnded {
            phase = .cancelled(.user)
        }
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
            AccountKeysText.log(error, while: "Reading the approval session")
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

    // An answer after the sheet closed or the session ended changes nothing: an ended session never shows words again.
    private func apply(_ session: ApprovalSessionInfo) {
        guard !closed, !phase.hasEnded else { return }
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
            settled = true
            phase = .approved
        case .takenElsewhere:
            settled = true
            phase = .takenElsewhere
        case .cancelled(let reason):
            settled = true
            phase = .cancelled(reason)
        case .expired:
            settled = true
            phase = .expired
        }
        stopPollingIfEnded()
    }

    private func stopPollingIfEnded() {
        guard phase.hasEnded else { return }
        polling?.cancel()
        polling = nil
    }

    private func act(_ body: @MainActor (any AccountKeyFlows) async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await body(try await flows())
        } catch {
            AccountKeysText.log(error, while: "An approval step")
            actionFailure = AccountKeysText.message(for: error)
        }
    }
}
