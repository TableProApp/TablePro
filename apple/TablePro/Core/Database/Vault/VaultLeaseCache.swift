//
//  VaultLeaseCache.swift
//  TablePro
//

import CryptoKit
import Foundation
import os
import TableProPluginKit
import TableProUtilities

// Every sign-in of one owner and role shares a lease, so a database still loading a new user meets the same user
// on the next attempt instead of yet another new one.
final class VaultLeaseCache: Sendable {
    struct Key: Hashable, Sendable {
        let owner: UUID
        let role: VaultDatabaseRole
        let endpoint: VaultEndpoint
        // Vault Agent reuses a lease only for the token that read it; so does this.
        let tokenDigest: Data

        init(owner: UUID, role: VaultDatabaseRole, endpoint: VaultEndpoint, token: String) {
            self.owner = owner
            self.role = role
            self.endpoint = endpoint
            self.tokenDigest = Data(SHA256.hash(data: Data(token.utf8)))
        }

        func reading(with token: String) -> Key {
            Key(owner: owner, role: role, endpoint: endpoint, token: token)
        }
    }

    struct Issued: Sendable {
        let username: String
        let password: String
        let lease: VaultLease
        // A re-login while reading leaves the lease with another token than the one the request was keyed by.
        let token: String
    }

    // An unused lease goes when the pool lets an unused connection go.
    static let idleRetention: Duration = .seconds(MetadataConnectionPool.idleTimeout)
    // Vitess, ProxySQL and replicas refuse a user Vault just created until they load it. HashiCorp's Terraform
    // provider retries a new credential for the same 30 seconds, then gives up on it.
    static let acceptanceWindow: Duration = .seconds(30)
    // Vault's own default request timeout.
    static let vaultRequestTimeout: Duration = .seconds(30)

    let clock: any Clock<Duration>
    // Starts timing a lease's age on `clock`.
    private let stopwatch: @Sendable () -> @Sendable () -> Duration
    private let state = OSAllocatedUnfairLock(initialState: State())

    init<C: Clock<Duration>>(clock: C = ContinuousClock()) {
        self.clock = clock
        stopwatch = {
            let start = clock.now
            return { start.duration(to: clock.now) }
        }
    }

    // `connection` is the connection that signs in, nil for a test of the source alone.
    func acquire(
        _ key: Key,
        for connection: UUID?,
        issue: @escaping @Sendable () async throws -> Issued
    ) async throws -> VaultLeaseHold {
        let lookup = state.withLock { state -> Lookup in
            if let id = state.listed[key], let hold = attach(to: id, for: connection, joinedRead: false, in: &state) {
                return .held(hold)
            }
            if var running = state.minting[key] {
                running.waiters += 1
                state.minting[key] = running
                return .reading(running.task)
            }
            let task = read(key, issue: issue)
            state.minting[key] = Minting(task: task, waiters: 1)
            return .reading(task)
        }
        switch lookup {
        case .held(let hold):
            return hold
        case .reading(let task):
            let id = try await task.value
            // Only a quit that revoked everything takes a slot from under a sign-in that joined its read.
            guard let hold = state.withLock({ attach(to: id, for: connection, joinedRead: true, in: &$0) }) else {
                throw CancellationError()
            }
            return hold
        }
    }

    // The user ended `connection`. A lease no connection in `live` signed in with is no longer handed out, and goes
    // once its last driver lets go, which a pooled read or a backup can do after this returns.
    func endUse(connection: UUID, live: Set<UUID>) {
        let leases = state.withLock { state -> [VaultLease] in
            let ended = state.slots.compactMap { id, slot -> UInt64? in
                slot.users.contains(connection) ? id : nil
            }
            return ended.compactMap { id in
                state.slots[id]?.users.remove(connection)
                guard state.slots[id]?.users.isDisjoint(with: live) == true else { return nil }
                unlist(id, in: &state)
                return settle(id, in: &state)
            }
        }
        leases.forEach { $0.release() }
    }

    // A revoke sent from a detached task at quit never leaves the process, so these are awaited, within `limit`.
    func revokeAll(within limit: Duration) async {
        let leases = state.withLock { state -> [VaultLease] in
            state.closed = true
            return Array(state.slots.keys).compactMap { drop($0, in: &state) }
        }
        guard !leases.isEmpty else { return }
        let clock = clock
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { revokes in
                    for lease in leases {
                        revokes.addTask { await lease.revoke() }
                    }
                }
            }
            group.addTask {
                try? await clock.sleep(for: limit)
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Holds

    fileprivate func subscribe(slot id: UInt64, hold: UInt64, onEnding: @escaping @Sendable (Duration) -> Void) {
        let ended = state.withLock { state -> Duration? in
            guard state.slots[id]?.holds[hold] != nil else { return nil }
            state.slots[id]?.holds[hold]?.onEnding = onEnding
            return state.slots[id]?.ending
        }
        if let ended { onEnding(ended) }
    }

    // `ending` revokes the lease too, unless another hold still uses it.
    fileprivate func release(slot id: UInt64, hold: UInt64, ending: Bool) {
        let lease = state.withLock { state -> VaultLease? in
            guard state.slots[id]?.holds.removeValue(forKey: hold) != nil else { return nil }
            if ending, state.slots[id]?.isIdle == true {
                unlist(id, in: &state)
            }
            return settle(id, in: &state)
        }
        lease?.release()
    }

    // A refusal alone cannot say whether Vault revoked the user or the database turned it away for its own reasons
    // (another database, a privilege, a user it has not loaded), so Vault is asked. Only a lease it no longer has ends.
    fileprivate func signInAccepted(slot id: UInt64) {
        state.withLock { $0.slots[id]?.accepted = true }
    }

    fileprivate func signInRefused(slot id: UInt64, credentials: Bool) {
        let lease = state.withLock { state -> VaultLease? in
            guard let slot = state.slots[id], slot.ending == nil else { return nil }
            if credentials {
                state.slots[id]?.credentialsRefused = true
            }
            guard !slot.asking else { return nil }
            state.slots[id]?.asking = true
            return slot.issued.lease
        }
        guard let lease else { return }
        Task { [weak self] in
            let exists = await lease.stillExists(timeout: Self.vaultRequestTimeout)
            self?.answered(id, exists: exists)
        }
    }

    fileprivate func hasEnded(slot id: UInt64) -> Bool {
        state.withLock { $0.slots[id]?.ending != nil }
    }

    fileprivate func redialDelay(slot id: UInt64, afterFailures failures: Int) -> Duration? {
        state.withLock { state -> Duration? in
            guard let slot = state.slots[id], slot.ending == nil, !slot.issued.lease.hasEnded else { return nil }
            let left = Self.acceptanceWindow - slot.age()
            guard left > .zero else { return nil }
            return min(.seconds(ExponentialBackoff.delay(for: failures)), left)
        }
    }

    // MARK: - State

    private struct Holder: Sendable {
        var onEnding: (@Sendable (Duration) -> Void)?
    }

    private struct Slot: Sendable {
        let key: Key
        let issued: Issued
        let age: @Sendable () -> Duration
        // Sign-ins that joined the read and have not taken their hold yet.
        var joinedReads: Int
        var holds: [UInt64: Holder] = [:]
        // Connections that signed in with it and were not ended since.
        var users: Set<UUID> = []
        // Vault is being asked whether it still has the lease.
        var asking = false
        var accepted = false
        var credentialsRefused = false
        var ending: Duration?
        var idleRelease: Task<Void, Never>?

        var isIdle: Bool { holds.isEmpty && joinedReads == 0 }
    }

    private struct Minting: Sendable {
        let task: Task<UInt64, Error>
        var waiters: Int
    }

    private enum Lookup: Sendable {
        case held(VaultLeaseHold)
        case reading(Task<UInt64, Error>)
    }

    private struct State: Sendable {
        var slots: [UInt64: Slot] = [:]
        var listed: [Key: UInt64] = [:]
        var minting: [Key: Minting] = [:]
        var nextId: UInt64 = 0
        // Set at quit: a lease read after the revoke would outlive the app.
        var closed = false
    }

    private func read(_ key: Key, issue: @escaping @Sendable () async throws -> Issued) -> Task<UInt64, Error> {
        Task {
            let issued: Issued
            do {
                issued = try await issue()
            } catch {
                state.withLock { _ = $0.minting.removeValue(forKey: key) }
                throw error
            }
            guard let (id, replaced) = register(issued, requestedAs: key) else {
                issued.lease.release()
                throw CancellationError()
            }
            replaced?.release()
            hearEnding(of: issued.lease, slot: id)
            return id
        }
    }

    private func hearEnding(of lease: VaultLease, slot id: UInt64) {
        lease.start { [weak self] remaining in
            self?.leaseEnding(id, remaining: remaining)
        }
    }

    private func register(_ issued: Issued, requestedAs requested: Key) -> (UInt64, replaced: VaultLease?)? {
        let age = stopwatch()
        return state.withLock { state in
            let waiters = state.minting.removeValue(forKey: requested)?.waiters ?? 0
            guard !state.closed else { return nil }
            let key = requested.reading(with: issued.token)
            var replaced: VaultLease?
            if let previous = state.listed[key] {
                unlist(previous, in: &state)
                replaced = settle(previous, in: &state)
            }
            state.nextId &+= 1
            let id = state.nextId
            state.slots[id] = Slot(key: key, issued: issued, age: age, joinedReads: waiters)
            state.listed[key] = id
            return (id, replaced)
        }
    }

    // Nil for a slot that is gone, or, outside a joined read, for a lease that ended before its ending was handled.
    private func attach(to id: UInt64, for connection: UUID?, joinedRead: Bool, in state: inout State) -> VaultLeaseHold? {
        guard var slot = state.slots[id] else { return nil }
        if joinedRead {
            slot.joinedReads -= 1
        } else if slot.issued.lease.hasEnded {
            return nil
        }
        slot.idleRelease?.cancel()
        slot.idleRelease = nil
        state.nextId &+= 1
        let hold = state.nextId
        slot.holds[hold] = Holder()
        if let connection {
            slot.users.insert(connection)
        }
        state.slots[id] = slot
        return VaultLeaseHold(cache: self, slot: id, hold: hold, issued: slot.issued)
    }

    private func answered(_ id: UInt64, exists: Bool?) {
        let (lead, dropped) = state.withLock { state -> (Duration?, VaultLease?) in
            guard let slot = state.slots[id] else { return (nil, nil) }
            state.slots[id]?.asking = false
            state.slots[id]?.credentialsRefused = false
            // Vault renews most engines' users without asking the database, so a user dropped there still exists to
            // Vault. Once a server took it and then refused its password, new sign-ins read another; sessions keep it.
            if exists != false, slot.accepted, slot.credentialsRefused {
                unlist(id, in: &state)
                return (nil, settle(id, in: &state))
            }
            return (slot.issued.lease.endingLead, nil)
        }
        dropped?.release()
        if exists == false, let lead {
            leaseEnding(id, remaining: lead)
        }
    }

    private func leaseEnding(_ id: UInt64, remaining: Duration) {
        let (handlers, lease) = state.withLock { state -> ([@Sendable (Duration) -> Void], VaultLease?) in
            guard let slot = state.slots[id], slot.ending == nil else { return ([], nil) }
            state.slots[id]?.ending = remaining
            unlist(id, in: &state)
            let handlers = state.slots[id]?.holds.values.compactMap(\.onEnding) ?? []
            return (handlers, settle(id, in: &state))
        }
        handlers.forEach { $0(remaining) }
        lease?.release()
    }

    private func expireIdle(_ id: UInt64) {
        let lease = state.withLock { state -> VaultLease? in
            guard state.slots[id]?.isIdle == true else { return nil }
            return drop(id, in: &state)
        }
        lease?.release()
    }

    // For a slot that may have lost its last user: an unlisted one goes now, a listed one after the retention.
    private func settle(_ id: UInt64, in state: inout State) -> VaultLease? {
        guard let slot = state.slots[id], slot.isIdle else { return nil }
        guard state.listed[slot.key] == id else { return drop(id, in: &state) }
        slot.idleRelease?.cancel()
        let clock = clock
        state.slots[id]?.idleRelease = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.idleRetention)
            } catch {
                return
            }
            self?.expireIdle(id)
        }
        return nil
    }

    private func unlist(_ id: UInt64, in state: inout State) {
        guard let key = state.slots[id]?.key, state.listed[key] == id else { return }
        state.listed[key] = nil
    }

    private func drop(_ id: UInt64, in state: inout State) -> VaultLease? {
        guard let slot = state.slots.removeValue(forKey: id) else { return nil }
        slot.idleRelease?.cancel()
        if state.listed[slot.key] == id {
            state.listed[slot.key] = nil
        }
        return slot.issued.lease
    }
}

// One user of a cached lease. Releasing it, or dropping the last reference to it, hands the lease back.
final class VaultLeaseHold: Sendable {
    let username: String
    let password: String
    let leaseId: String

    private let lease: VaultLease
    private let cache: VaultLeaseCache
    private let slot: UInt64
    private let hold: UInt64
    private let released = OSAllocatedUnfairLock(initialState: false)

    fileprivate init(cache: VaultLeaseCache, slot: UInt64, hold: UInt64, issued: VaultLeaseCache.Issued) {
        self.cache = cache
        self.slot = slot
        self.hold = hold
        self.username = issued.username
        self.password = issued.password
        self.leaseId = issued.lease.leaseId
        self.lease = issued.lease
    }

    deinit {
        release()
    }

    var hasEnded: Bool { lease.hasEnded || cache.hasEnded(slot: slot) }

    var clock: any Clock<Duration> { cache.clock }

    // `onEnding` gets how long the lease has left, which is the time to sign in again in.
    func start(onEnding: @escaping @Sendable (Duration) -> Void) {
        cache.subscribe(slot: slot, hold: hold, onEnding: onEnding)
    }

    func release() {
        release(ending: false)
    }

    // For a user whose password left the process, such as a backup tool's arguments: revoked as soon as nothing
    // else holds it, not kept for the next sign-in.
    func end() {
        release(ending: true)
    }

    private func release(ending: Bool) {
        let first = released.withLock { released -> Bool in
            defer { released = true }
            return !released
        }
        guard first else { return }
        cache.release(slot: slot, hold: hold, ending: ending)
    }

    func signInAccepted() {
        cache.signInAccepted(slot: slot)
    }

    // `credentials`: the server named the password or user as the reason, as MySQL's 1045 does.
    func signInRefused(credentials: Bool) {
        cache.signInRefused(slot: slot, credentials: credentials)
    }

    // Nil once the lease is past the acceptance window or has ended: a refusal then is final.
    func redialDelay(afterFailures failures: Int) -> Duration? {
        cache.redialDelay(slot: slot, afterFailures: failures)
    }

    // Dials until the database takes this user, while the lease is young. `waiting` hears each wait before it
    // starts; `isCurrent` says whether the connect still wants a dial once it ends.
    func dial(
        _ connect: () async throws -> Void,
        waiting: (Duration) -> Void,
        isCurrent: () -> Bool
    ) async throws {
        let startedYoung = redialDelay(afterFailures: 1) != nil
        var failures = 0
        while true {
            do {
                try await connect()
                return
            } catch {
                guard let refusal = error as? any PluginDriverError, Self.isRefusedSignIn(refusal) else { throw error }
                failures += 1
                guard let delay = redialDelay(afterFailures: failures) else {
                    throw startedYoung && !hasEnded ? VaultUserNotLoaded(refusal: refusal) : error
                }
                waiting(delay)
                try await clock.sleep(for: delay)
                guard isCurrent() else { throw CancellationError() }
                guard !hasEnded else { throw error }
            }
        }
    }

    // MySQL answers 1045 for a user it has not loaded yet, the same as for a wrong password.
    static func isRefusedSignIn(_ error: Error) -> Bool {
        guard let error = error as? any PluginDriverError else { return false }
        return error.pluginErrorCode == 1_045 && error.pluginSqlState == "28000"
    }
}

extension VaultLeaseHold: Equatable {
    static func == (lhs: VaultLeaseHold, rhs: VaultLeaseHold) -> Bool { lhs === rhs }
}

// A new Vault user the server refused for the whole acceptance window. The lease is kept, so the next attempt meets
// the same user, which the server may have loaded by then.
struct VaultUserNotLoaded: PluginDriverError {
    let refusal: any PluginDriverError

    var pluginErrorMessage: String { refusal.pluginErrorMessage }
    var pluginErrorCode: Int? { refusal.pluginErrorCode }
    var pluginSqlState: String? { refusal.pluginSqlState }
    var pluginErrorDetail: String? { refusal.pluginErrorDetail }

    var recoverySuggestion: String? {
        String(
            format: String(localized: """
                The database refused the new user Vault created for it for %lld seconds. Some databases load new \
                users on a timer, so try again in a moment.
                """),
            Int64(VaultLeaseCache.acceptanceWindow.components.seconds)
        )
    }
}
