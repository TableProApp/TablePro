//
//  VaultLease.swift
//  TablePro
//

import Foundation
import os

struct VaultLeaseGrant: Equatable, Sendable {
    let leaseDuration: Duration
    // How long the token that owns the lease has left. Vault revokes the lease when that token expires.
    let tokenRemaining: Duration?
}

protocol VaultLeaseRenewing: Sendable {
    func renew(leaseId: String, increment: Duration, timeout: Duration) async throws -> VaultLeaseGrant
    func revoke(leaseId: String) async
}

// Measured from the moment of the latest grant.
struct VaultLeaseSchedule: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case renew(after: Duration)
        case end(after: Duration)
    }

    let initialDuration: Duration
    let renewable: Bool
    // The first horizon. Fixed for the lease's life, so grants shrinking toward the max TTL end it.
    var leadBasis: Duration

    init(initialDuration: Duration, renewable: Bool, leadBasis: Duration? = nil) {
        self.initialDuration = initialDuration
        self.renewable = renewable
        self.leadBasis = leadBasis ?? initialDuration
    }

    // Rotating ahead of the end leaves the reconnect time to sign in again before the user is dropped.
    var lead: Duration {
        min(max(leadBasis / 10, .seconds(10)), .seconds(120), leadBasis / 4)
    }

    func next(after grant: VaultLeaseGrant) -> Step {
        var horizon = grant.leaseDuration
        if let tokenRemaining = grant.tokenRemaining {
            horizon = min(horizon, tokenRemaining)
        }
        let renewAt = horizon * 2 / 3
        // Renewing past here buys less than the lead, which is how a lease reaching its max TTL ends.
        if renewable, renewAt < horizon - lead {
            return .renew(after: renewAt)
        }
        return .end(after: max(.zero, horizon - lead))
    }

    func retryDelay(attempt: Int) -> Duration {
        min(.seconds(5) * (1 << min(attempt, 4)), .seconds(60))
    }
}

// Owned by whatever signed in with it, a driver or a backup job. Dropping the last reference revokes it too, so a
// lease a timed-out connect never adopted does not outlive it.
final class VaultLease: Sendable {
    let leaseId: String

    private let renewer: any VaultLeaseRenewing
    private let schedule: VaultLeaseSchedule
    private let firstGrant: VaultLeaseGrant
    private let clock: any Clock<Duration>
    private let control = Control()

    private static let logger = Logger(subsystem: "com.TablePro", category: "VaultLease")

    // `grant` is what is left now; `increment` is the TTL Vault granted, which every renewal asks for again.
    init(
        leaseId: String,
        grant: VaultLeaseGrant,
        increment: Duration? = nil,
        renewable: Bool,
        renewer: any VaultLeaseRenewing,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.leaseId = leaseId
        self.renewer = renewer
        let increment = increment ?? grant.leaseDuration
        self.schedule = VaultLeaseSchedule(
            initialDuration: increment,
            renewable: renewable,
            leadBasis: min(increment, grant.tokenRemaining ?? increment)
        )
        self.firstGrant = grant
        self.clock = clock
    }

    deinit {
        release()
    }

    var hasEnded: Bool { control.hasEnded }

    // `onEnding` gets how long the lease has left, which is the time to sign in again in.
    func start(onEnding: @escaping @Sendable (Duration) -> Void) {
        let leaseId = leaseId
        let renewer = renewer
        let schedule = schedule
        let firstGrant = firstGrant
        let clock = clock
        let control = control
        control.start {
            Task.detached(priority: .utility) {
                await Self.keepAlive(
                    leaseId: leaseId,
                    renewer: renewer,
                    schedule: schedule,
                    firstGrant: firstGrant,
                    clock: clock
                )
                guard !Task.isCancelled, control.markEnded() else { return }
                onEnding(schedule.lead)
            }
        }
    }

    func release() {
        guard control.release() else { return }
        let leaseId = leaseId
        let renewer = renewer
        Task.detached(priority: .utility) {
            await renewer.revoke(leaseId: leaseId)
        }
    }

    // Returns when the lease is about to end and can no longer be renewed.
    private static func keepAlive(
        leaseId: String,
        renewer: any VaultLeaseRenewing,
        schedule: VaultLeaseSchedule,
        firstGrant: VaultLeaseGrant,
        clock: any Clock<Duration>
    ) async {
        var grant = firstGrant
        while !Task.isCancelled {
            switch schedule.next(after: grant) {
            case .end(let after):
                try? await clock.sleep(for: after)
                return
            case .renew(let after):
                do {
                    try await clock.sleep(for: after)
                } catch {
                    return
                }
                let horizon = min(grant.leaseDuration, grant.tokenRemaining ?? grant.leaseDuration)
                guard let renewed = await renew(
                    leaseId: leaseId,
                    renewer: renewer,
                    schedule: schedule,
                    remaining: horizon - after,
                    clock: clock
                ) else { return }
                grant = renewed
            }
        }
    }

    // Retries a failed renewal while the lease still has time; nil once it has to end.
    private static func renew(
        leaseId: String,
        renewer: any VaultLeaseRenewing,
        schedule: VaultLeaseSchedule,
        remaining initialRemaining: Duration,
        clock: any Clock<Duration>
    ) async -> VaultLeaseGrant? {
        var remaining = initialRemaining
        var attempt = 0
        while !Task.isCancelled {
            // A slow Vault spends the lease too, so each attempt gets only what is left before the lead.
            let budget = remaining - schedule.lead
            guard budget > .zero else { return nil }
            let (outcome, elapsed) = await measure(on: clock) { () async -> Result<VaultLeaseGrant, Error> in
                do {
                    return .success(try await renewer.renew(
                        leaseId: leaseId,
                        increment: schedule.initialDuration,
                        timeout: budget
                    ))
                } catch {
                    return .failure(error)
                }
            }
            remaining -= elapsed
            switch outcome {
            case .success(let grant):
                return grant
            case .failure(let error):
                logger.warning("Could not renew a Vault lease: \(error.publicLogShape, privacy: .public)")
                // A revoked lease or a refused token will not renew on a retry; signing in again might work.
                if isDefinitive(error) { return nil }
            }
            let delay = schedule.retryDelay(attempt: attempt)
            attempt += 1
            let untilEnding = remaining - schedule.lead
            guard delay < untilEnding else {
                try? await clock.sleep(for: max(.zero, untilEnding))
                return nil
            }
            do {
                try await clock.sleep(for: delay)
            } catch {
                return nil
            }
            remaining -= delay
        }
        return nil
    }

    private static func measure<C: Clock<Duration>, Value>(
        on clock: C,
        _ body: () async -> Value
    ) async -> (Value, Duration) {
        let start = clock.now
        let value = await body()
        return (value, start.duration(to: clock.now))
    }

    static func isDefinitive(_ error: Error) -> Bool {
        if let request = error as? VaultRequestError {
            return (400 ..< 500).contains(request.status) && request.status != 429
        }
        if case .unreachable = error as? VaultError { return false }
        return error is VaultError
    }

    private final class Control: Sendable {
        private struct State {
            var task: Task<Void, Never>?
            var released = false
            var ended = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var hasEnded: Bool { state.withLock { $0.ended } }

        func start(_ makeTask: () -> Task<Void, Never>) {
            state.withLockUnchecked { state in
                guard !state.released, state.task == nil else { return }
                state.task = makeTask()
            }
        }

        func markEnded() -> Bool {
            state.withLock { state in
                guard !state.released, !state.ended else { return false }
                state.ended = true
                return true
            }
        }

        // True only for the first release.
        func release() -> Bool {
            let task = state.withLock { state -> Task<Void, Never>?? in
                guard !state.released else { return nil }
                state.released = true
                defer { state.task = nil }
                return .some(state.task)
            }
            guard let task else { return false }
            task?.cancel()
            return true
        }
    }
}

extension VaultLease: Equatable {
    static func == (lhs: VaultLease, rhs: VaultLease) -> Bool { lhs === rhs }
}
