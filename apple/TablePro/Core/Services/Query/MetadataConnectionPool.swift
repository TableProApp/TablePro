//
//  MetadataConnectionPool.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

// The lease a task's work runs under. That work keeps the lease until a lease it asks for returns, so such a
// request never waits for room; a task started inside keeps the exemption only while the lease is open.
@MainActor
private final class PooledLease {
    let connectionId: UUID
    // A lease nested in this one never takes this entry: it would queue behind the work that waits on it.
    let entryId: ObjectIdentifier
    var isOpen = true

    init(connectionId: UUID, entryId: ObjectIdentifier) {
        self.connectionId = connectionId
        self.entryId = entryId
    }
}

private enum PooledLeaseContext {
    @TaskLocal static var open: [PooledLease] = []
}

@MainActor
final class MetadataConnectionPool {
    static let shared = MetadataConnectionPool()

    enum Workload: Hashable, Sendable {
        case interactive
        case bulk
    }

    // A scope with no schema reads wherever the connection's own settings put it, so its entries never switch.
    private enum Slot: Hashable, Sendable {
        case home
        case followsSchema
    }

    // No schema in the key: an entry moves to each lease's schema, so the schemas of one database share connections.
    private struct Key: Hashable, Sendable {
        let connectionId: UUID
        let database: String
        let workload: Workload
        let slot: Slot

        init(scope: DatabaseScope, workload: Workload) {
            connectionId = scope.connectionId
            database = scope.database
            self.workload = workload
            slot = scope.schema == nil ? .home : .followsSchema
        }
    }

    private struct OpenKey: Hashable, Sendable {
        let key: Key
        let schema: String?
        // Set for a lease inside another lease's work, so its open is its own and nobody queues on it.
        let owner: UUID?
    }

    private enum LeaseOutcome<T: Sendable>: Sendable {
        case ran(T)
        // The entry was left in a transaction and is closing, so the lease takes another.
        case retired
    }

    @MainActor
    private final class Entry {
        let driver: DatabaseDriver
        var lastUsed = Date()
        var inFlightCount = 0
        var closeWhenIdle = false
        // The schema the last lease moved it to, used only to pick an entry; nil until a lease has moved it.
        var schema: String?
        // Only leases on one schema queue on a busy entry, so this is the schema its queue is on.
        var queuedSchema: String?
        // A startup command can move the search path after the driver read it, so the driver's cache is not trusted.
        var forcesNextSwitch: Bool
        var hasServedALease = false
        private var tail: Task<Void, Never> = Task {}

        init(driver: DatabaseDriver, schema: String?, forcesNextSwitch: Bool) {
            self.driver = driver
            self.schema = schema
            self.queuedSchema = schema
            self.forcesNextSwitch = forcesNextSwitch
        }

        // The work runs in its own task so the next caller can queue behind it, so a cancel is forwarded by hand.
        func runSerially<T: Sendable>(
            connectionId: UUID,
            prepare: @escaping @MainActor @Sendable (Entry) async throws -> Bool,
            _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
        ) async throws -> LeaseOutcome<T> {
            let previous = tail
            let driver = self.driver
            let work = Task { @MainActor [self] () async throws -> LeaseOutcome<T> in
                await previous.value
                try Task.checkCancellation()
                guard try await prepare(self) else { return .retired }
                hasServedALease = true
                let lease = PooledLease(connectionId: connectionId, entryId: ObjectIdentifier(self))
                defer { lease.isOpen = false }
                let value = try await PooledLeaseContext.$open.withValue(PooledLeaseContext.open + [lease]) {
                    try await body(driver)
                }
                return .ran(value)
            }
            tail = Task { @MainActor in _ = try? await work.value }
            return try await withTaskCancellationHandler(
                operation: { try await work.value },
                onCancel: { work.cancel() }
            )
        }
    }

    typealias DriverOpener = @MainActor (DatabaseScope) async throws -> DatabaseDriver

    // Why an open still in progress was taken away from the callers waiting on it.
    private enum Withdrawal {
        // The transport it was dialing is being rebuilt, so its callers take a connection again after the replacement.
        case transportReplaced
        // What it was opened for is going away, so nothing may open it again.
        case closed
    }

    // Shared by every caller that asks for its key and schema while it runs. It stays listed until the last of them
    // has taken its entry, because an entry nobody has taken yet looks idle and would be the first one closed.
    @MainActor
    private final class PendingOpen {
        var task: Task<Void, Error>?
        var entry: Entry?
        var withdrawal: Withdrawal?
        var waiterCount = 0
    }

    private struct TransportWaiter {
        let ticket: UUID
        let scope: DatabaseScope
        let continuation: CheckedContinuation<Void, Error>
    }

    @MainActor
    private final class RoomTicket {
        let key: Key
        let schema: String?
        let held: Set<ObjectIdentifier>
        var continuation: CheckedContinuation<Void, Error>?
        var isWithdrawn = false

        init(key: Key, schema: String?, held: Set<ObjectIdentifier>) {
            self.key = key
            self.schema = schema
            self.held = held
        }
    }

    private var entries: [Key: [Entry]] = [:]
    private var pending: [OpenKey: PendingOpen] = [:]
    private var transportReplacements: [UUID: Int] = [:]
    private var transportWaiters: [UUID: [TransportWaiter]] = [:]
    private var roomQueues: [UUID: [RoomTicket]] = [:]
    private let openDriver: DriverOpener
    static let maxPerConnection = 6
    private var sweeper: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.TablePro", category: "MetadataConnectionPool")

    /// How long a pooled connection may sit unused before it is handed back.
    ///
    /// These are connections the user never opened: the pool takes one per database the sidebar
    /// touches, up to six, and the only thing that ever closed one was the count cap at acquire
    /// time or the whole connection going away. Browsing six databases and then leaving the app
    /// open left six idle server connections held for as long as it ran (#2700).
    ///
    /// Ten minutes rather than something tighter, because re-taking one is a whole connect,
    /// measured at 1.7-5.8ms on loopback but 800-1900ms across the internet, and someone still
    /// working must never pay that. Ten minutes of silence is nobody still working.
    static let idleTimeout: TimeInterval = 600

    /// The sweeper wakes more often than the timeout so a connection that goes idle just after a
    /// tick does not wait a whole second timeout, and never so often that an idle app spends the
    /// day waking up.
    private static let sweepInterval: Duration = .seconds(60)

    private init(openDriver: DriverOpener? = nil) {
        self.openDriver = openDriver ?? { scope in
            try await MetadataConnectionPool.openServerDriver(for: scope, purpose: .metadata)
        }
    }

    func withDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let key = Key(scope: scope, workload: workload)
        while true {
            let entry = try await acquireEntry(forKey: key, schema: scope.schema, scope: scope)
            if case .ran(let value) = try await run(body, on: entry, inKey: key, schema: scope.schema) {
                return value
            }
        }
    }

    private func run<T: Sendable>(
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T,
        on entry: Entry,
        inKey key: Key,
        schema: String?
    ) async throws -> LeaseOutcome<T> {
        defer { releaseEntry(entry, connectionId: key.connectionId) }
        return try await entry.runSerially(
            connectionId: key.connectionId,
            prepare: { [self] entry in try await moveEntry(entry, inKey: key, to: schema) },
            body
        )
    }

    /// Closes only the leases attached to one database, which is what a rename of that database
    /// needs: PostgreSQL refuses `ALTER DATABASE ... RENAME` while any backend is connected to it,
    /// and an expanded row or a tab that ran a query there leaves one here.
    func closeAll(connectionId: UUID, database: String) {
        closeEntries(withdrawingOpensAs: .closed) { $0 == connectionId && $1 == database }
    }

    func closeAll(connectionId: UUID) {
        closeEntries(withdrawingOpensAs: .closed) { id, _ in id == connectionId }
    }

    // Holds a connection's pooled work while its transport is rebuilt: a tunnel on a new local port, or a reconnect of
    // a connection that stopped answering. An open already dialing is withdrawn and its callers take a connection again
    // after `endTransportReplacement`; a new caller waits for that too. Replacements nest. Closing the connection, or
    // one of its databases, fails the callers waiting for it.
    func beginTransportReplacement(connectionId: UUID) {
        transportReplacements[connectionId, default: 0] += 1
        closeEntries(withdrawingOpensAs: .transportReplaced) { id, _ in id == connectionId }
    }

    /// Has to follow every `beginTransportReplacement` on every exit, cancellation included, or the
    /// connection's pooled work waits for good.
    func endTransportReplacement(connectionId: UUID) {
        guard let depth = transportReplacements[connectionId] else { return }
        guard depth == 1 else {
            transportReplacements[connectionId] = depth - 1
            return
        }
        transportReplacements.removeValue(forKey: connectionId)
        for waiter in transportWaiters.removeValue(forKey: connectionId) ?? [] {
            waiter.continuation.resume()
        }
    }

    #if DEBUG
    // Seeds a connected driver as a pooled connection already on `scope`'s schema, for a test with no plugin to open one.
    internal func injectEntry(
        _ driver: DatabaseDriver,
        scope: DatabaseScope,
        workload: Workload = .interactive,
        lastUsed: Date = Date()
    ) {
        let entry = Entry(driver: driver, schema: scope.schema, forcesNextSwitch: false)
        entry.lastUsed = lastUsed
        entry.hasServedALease = true
        entries[Key(scope: scope, workload: workload), default: []].append(entry)
    }

    internal func pooledDriverCount(for connectionId: UUID) -> Int {
        pooled(on: connectionId).count
    }

    internal func heldConnectionCount(for connectionId: UUID) -> Int {
        heldCount(for: connectionId)
    }

    internal func leaseCount(for connectionId: UUID) -> Int {
        pooled(on: connectionId).reduce(0) { $0 + $1.entry.inFlightCount }
    }

    internal func markInFlight(scope: DatabaseScope, workload: Workload = .interactive) {
        let list = entries[Key(scope: scope, workload: workload)] ?? []
        let entry = list.first(where: { $0.schema == scope.schema }) ?? list.first
        entry?.inFlightCount += 1
    }

    internal var hasSweeper: Bool {
        sweeper != nil
    }

    /// The sweeper is started by opening a pooled connection, which a test with no plugin cannot
    /// do, so a test that wants to watch it stop has to start it the way `openEntry` does.
    internal func startSweeperForTesting() {
        startSweeperIfNeeded()
    }

    /// A pool of its own, so a test that moves the clock or empties the pool cannot close the
    /// entries another test injected into the shared one. `openDriver` stands in for opening a real
    /// connection, which a test with no plugin cannot do.
    internal static func isolatedForTesting(openDriver: DriverOpener? = nil) -> MetadataConnectionPool {
        MetadataConnectionPool(openDriver: openDriver)
    }

    /// How many callers are waiting for a transport replacement to end, so a test can wait for one
    /// to park instead of guessing how many scheduler turns that takes.
    internal func transportWaiterCount(for connectionId: UUID) -> Int {
        transportWaiters[connectionId]?.count ?? 0
    }

    internal func roomWaiterCount(for connectionId: UUID) -> Int {
        roomQueues[connectionId]?.filter { $0.continuation != nil }.count ?? 0
    }
    #endif

    /// Whether the connection's transport is being rebuilt, which ends every connection dialed
    /// through it, so nothing new should be opened or promoted onto it until that is over.
    internal func isReplacingTransport(for connectionId: UUID) -> Bool {
        transportReplacements[connectionId] != nil
    }

    private func releaseEntry(_ entry: Entry, connectionId: UUID) {
        entry.inFlightCount -= 1
        guard entry.inFlightCount == 0 else { return }
        if entry.closeWhenIdle {
            entry.driver.disconnect()
            return
        }
        trimIdleEntries(for: connectionId)
        handRoom(on: connectionId)
    }

    @discardableResult
    private func detach(_ entry: Entry, fromKey key: Key) -> Bool {
        guard var list = entries[key], let index = list.firstIndex(where: { $0 === entry }) else { return false }
        list.remove(at: index)
        entries[key] = list.isEmpty ? nil : list
        return true
    }

    private func removeEntry(_ entry: Entry, fromKey key: Key) {
        guard detach(entry, fromKey: key) else { return }
        if entry.inFlightCount == 0 {
            entry.driver.disconnect()
        } else {
            entry.closeWhenIdle = true
        }
        handRoom(on: key.connectionId)
    }

    private func closeEntries(
        withdrawingOpensAs withdrawal: Withdrawal,
        where matches: (UUID, String) -> Bool
    ) {
        var withdrawnFrom: Set<UUID> = []
        for openKey in pending.keys where matches(openKey.key.connectionId, openKey.key.database) {
            guard let open = pending.removeValue(forKey: openKey) else { continue }
            open.withdrawal = withdrawal
            open.task?.cancel()
            withdrawnFrom.insert(openKey.key.connectionId)
        }
        if withdrawal == .closed {
            failTransportWaiters(where: matches)
            withdrawRoomTickets(where: matches)
        }
        for (key, list) in entries where matches(key.connectionId, key.database) {
            for entry in list {
                removeEntry(entry, fromKey: key)
            }
        }
        for connectionId in withdrawnFrom {
            handRoom(on: connectionId)
        }
        stopSweeperIfEmpty()
    }

    // A parked caller would otherwise wake when the replacement ends and open a connection for what has gone.
    private func failTransportWaiters(where matches: (UUID, String) -> Bool) {
        for (connectionId, waiters) in transportWaiters {
            let failing = waiters.filter { matches($0.scope.connectionId, $0.scope.database) }
            guard !failing.isEmpty else { continue }
            let remaining = waiters.filter { !matches($0.scope.connectionId, $0.scope.database) }
            transportWaiters[connectionId] = remaining.isEmpty ? nil : remaining
            for waiter in failing {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    // In order: an idle entry on the schema, any idle entry, the busy entry on the schema, an open for the schema
    // already dialing, a new entry if there is room, else a place in the room line. A lease inside another lease's
    // work skips the busy entry and the open: two such leases nesting in opposite directions would wait on each other.
    private func acquireEntry(forKey key: Key, schema: String?, scope: DatabaseScope) async throws -> Entry {
        let held = entriesHeldByThisTask()
        let openKey = OpenKey(key: key, schema: schema, owner: held.isEmpty ? nil : UUID())
        while true {
            try await waitForTransport(for: scope)
            if let entry = claimEntry(forKey: key, schema: schema, excluding: held) {
                return entry
            }
            if pending[openKey] == nil {
                try await waitForRoom(forKey: key, schema: schema, held: held)
                // A wait can outlast its reason: an entry came free, the schema's open started, or the transport is being rebuilt.
                if pending[openKey] != nil || placeWithoutOpening(forKey: key, schema: schema, excluding: held) != nil
                    || isReplacingTransport(for: key.connectionId) {
                    continue
                }
            }
            let open = try pending[openKey] ?? startOpen(openKey)
            let failure = await completion(of: open, for: openKey)
            // A withdrawn open can end either way: a driver whose connect honours cancellation throws, and one that
            // finished first returns without keeping its entry.
            if open.withdrawal == .transportReplaced {
                try Task.checkCancellation()
                continue
            }
            if let failure {
                throw failure
            }
            if let entry = open.entry, isListed(entry, inKey: key) {
                claim(entry, for: schema)
                return entry
            }
            if open.withdrawal == .closed {
                throw DatabaseError.notConnected
            }
            forgetSpentOpen(open, for: openKey)
        }
    }

    private func entriesHeldByThisTask() -> Set<ObjectIdentifier> {
        Set(PooledLeaseContext.open.filter { $0.isOpen }.map { $0.entryId })
    }

    private func claimEntry(forKey key: Key, schema: String?, excluding held: Set<ObjectIdentifier>) -> Entry? {
        // A Mac that slept comes back with entries the sweeper never reached and sockets the server already closed.
        for entry in entries[key] ?? [] where !isUsable(entry) {
            removeEntry(entry, fromKey: key)
        }
        guard let entry = placeWithoutOpening(forKey: key, schema: schema, excluding: held) else { return nil }
        claim(entry, for: schema)
        return entry
    }

    // At most one busy entry per schema, so two schemas share a connection only while one of them is idle.
    private func placeWithoutOpening(
        forKey key: Key,
        schema: String?,
        excluding held: Set<ObjectIdentifier>
    ) -> Entry? {
        let candidates = (entries[key] ?? []).filter { !held.contains(ObjectIdentifier($0)) && isUsable($0) }
        let idle = candidates.filter { isIdle($0) }
        if let onSchema = idle.first(where: { $0.schema == schema }) {
            return onSchema
        }
        if let any = idle.min(by: { $0.lastUsed < $1.lastUsed }) {
            return any
        }
        guard held.isEmpty else { return nil }
        return candidates.first { $0.inFlightCount > 0 && $0.queuedSchema == schema }
    }

    private func claim(_ entry: Entry, for schema: String?) {
        entry.inFlightCount += 1
        entry.lastUsed = Date()
        entry.queuedSchema = schema
    }

    // Runs on the entry's queue before the lease's work, so the switch lands where the work reads.
    private func moveEntry(_ entry: Entry, inKey key: Key, to schema: String?) async throws -> Bool {
        guard key.slot == .followsSchema, let schema, let switchable = entry.driver as? SchemaSwitchable else {
            return true
        }
        let unconditionally = entry.forcesNextSwitch
        // Asked on every lease: Snowflake's drivers for one connection share a session, so another one may have moved it.
        if !unconditionally, switchable.currentSchema == schema {
            entry.schema = schema
            return true
        }
        // A SET sent inside a transaction is undone by its rollback while the driver keeps the new name. A fresh
        // entry's transaction came from the startup commands, and every replacement would carry one too.
        if entry.hasServedALease {
            let state = await entry.driver.sessionTransactionState()
            if state == .inTransaction || state == .abortedTransaction {
                Self.logger.info("Closing a pooled connection left in a transaction instead of moving its schema")
                removeEntry(entry, fromKey: key)
                return false
            }
        }
        do {
            try await Self.switchSchema(
                entry.driver,
                to: schema,
                timeoutSeconds: Self.stepTimeoutSeconds(for: key.connectionId),
                unconditionally: unconditionally
            )
        } catch {
            // The server may have run a statement the client gave up on, so the next lease sends its own.
            entry.schema = nil
            entry.forcesNextSwitch = true
            if !Self.isConnected(entry.driver) {
                removeEntry(entry, fromKey: key)
            }
            throw error
        }
        entry.schema = schema
        entry.forcesNextSwitch = false
        return true
    }

    private static func stepTimeoutSeconds(for connectionId: UUID) -> Double? {
        guard let seconds = DatabaseManager.shared.session(for: connectionId)?.effectiveQueryTimeoutSeconds,
              seconds > 0
        else { return nil }
        return Double(seconds)
    }

    // Joining an open that has already finished returns without a suspension, so a caller that rejoined one whose entry
    // went would spin on the main actor and starve the callers still waiting to resume from it.
    private func forgetSpentOpen(_ open: PendingOpen, for openKey: OpenKey) {
        guard pending[openKey] === open else { return }
        pending.removeValue(forKey: openKey)
        handRoom(on: openKey.key.connectionId)
    }

    private static func isConnected(_ driver: DatabaseDriver) -> Bool {
        driver.status == .connected && !driver.hasLostConnection
    }

    private func isUsable(_ entry: Entry) -> Bool {
        Self.isConnected(entry.driver) && !Self.isStale(entry.lastUsed)
    }

    private func isListed(_ entry: Entry, inKey key: Key) -> Bool {
        entries[key]?.contains { $0 === entry } == true
    }

    private func isAwaitingItsOpeners(_ entry: Entry) -> Bool {
        pending.values.contains { $0.entry === entry }
    }

    private func isIdle(_ entry: Entry) -> Bool {
        entry.inFlightCount == 0 && !isAwaitingItsOpeners(entry)
    }

    // A new entry opens on the connection's own default and each lease moves it, so it can serve every schema.
    private func startOpen(_ openKey: OpenKey) throws -> PendingOpen {
        let key = openKey.key
        guard let session = DatabaseManager.shared.session(for: key.connectionId) else {
            throw DatabaseError.notConnected
        }
        evictIdleIfNeeded(for: key.connectionId)
        let scope = DatabaseScope(connectionId: key.connectionId, database: key.database, schema: nil)
        let forcesFirstSwitch = key.slot == .followsSchema
            && DatabaseManager.hasStartupCommands(session.connection.startupCommands)
        let open = PendingOpen()
        open.task = Task { [self] in
            let entry = Entry(driver: try await openDriver(scope), schema: nil, forcesNextSwitch: forcesFirstSwitch)
            if Task.isCancelled {
                entry.driver.disconnect()
                return
            }
            entries[key, default: []].append(entry)
            open.entry = entry
            startSweeperIfNeeded()
        }
        pending[openKey] = open
        return open
    }

    // Waits for an open to finish, takes it off the pending list once its last caller has, and returns how it failed.
    private func completion(of open: PendingOpen, for openKey: OpenKey) async -> Error? {
        open.waiterCount += 1
        defer {
            open.waiterCount -= 1
            if open.waiterCount == 0, pending[openKey] === open {
                pending.removeValue(forKey: openKey)
                // A failed open frees its place, and a taken one leaves an entry that is now evictable once idle.
                handRoom(on: openKey.key.connectionId)
            }
        }
        do {
            _ = try await open.task?.value
            return nil
        } catch {
            return error
        }
    }

    /// Parks a caller for as long as the connection's transport is being replaced. A caller that is
    /// cancelled while parked stops waiting at once rather than when the replacement ends.
    private func waitForTransport(for scope: DatabaseScope) async throws {
        let connectionId = scope.connectionId
        while transportReplacements[connectionId] != nil {
            let ticket = UUID()
            try await withTaskCancellationHandler(
                operation: { try await parkForTransport(ticket: ticket, scope: scope) },
                onCancel: { [weak self] in
                    Task { @MainActor in
                        self?.failTransportWaiter(ticket: ticket, connectionId: connectionId)
                    }
                }
            )
        }
    }

    private func parkForTransport(ticket: UUID, scope: DatabaseScope) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            transportWaiters[scope.connectionId, default: []].append(
                TransportWaiter(ticket: ticket, scope: scope, continuation: continuation)
            )
        }
    }

    /// Removes the ticket before resuming it, so a cancellation racing the end of a replacement can
    /// only ever find one of them.
    private func failTransportWaiter(ticket: UUID, connectionId: UUID) {
        guard var waiters = transportWaiters[connectionId],
              let index = waiters.firstIndex(where: { $0.ticket == ticket })
        else {
            return
        }
        let waiter = waiters.remove(at: index)
        transportWaiters[connectionId] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    // First come first served, interactive ahead of bulk; a caller arriving while others wait goes behind them.
    private func waitForRoom(forKey key: Key, schema: String?, held: Set<ObjectIdentifier>) async throws {
        let connectionId = key.connectionId
        guard !PooledLeaseContext.open.contains(where: { $0.isOpen && $0.connectionId == connectionId }) else { return }
        let ticket = RoomTicket(key: key, schema: schema, held: held)
        roomQueues[connectionId, default: []].append(ticket)
        defer { leaveRoomQueue(ticket) }
        while !mayOpen(ticket) {
            try await parkForRoom(ticket)
            try Task.checkCancellation()
            if ticket.isWithdrawn { throw CancellationError() }
        }
    }

    private func proceedsWithoutAPlace(_ ticket: RoomTicket) -> Bool {
        let key = ticket.key
        let joinsAnOpen = ticket.held.isEmpty && pending[OpenKey(key: key, schema: ticket.schema, owner: nil)] != nil
        return joinsAnOpen
            || placeWithoutOpening(forKey: key, schema: ticket.schema, excluding: ticket.held) != nil
            || isReplacingTransport(for: key.connectionId)
    }

    private func mayOpen(_ ticket: RoomTicket) -> Bool {
        if proceedsWithoutAPlace(ticket) { return true }
        let connectionId = ticket.key.connectionId
        return nextInLine(on: connectionId) === ticket && hasRoom(for: ticket.key.workload, on: connectionId)
    }

    private func nextInLine(on connectionId: UUID) -> RoomTicket? {
        let line = roomQueues[connectionId] ?? []
        return line.first { $0.key.workload == .interactive } ?? line.first
    }

    // A freed place goes only to the caller next in line. Callers that need no new place go too, and first, so an
    // idle entry is reused before the next in line can evict it.
    private func handRoom(on connectionId: UUID) {
        let parked = (roomQueues[connectionId] ?? []).filter { $0.continuation != nil }
        var woken = parked.filter { proceedsWithoutAPlace($0) }
        if let next = nextInLine(on: connectionId), next.continuation != nil,
           !woken.contains(where: { $0 === next }), mayOpen(next) {
            woken.append(next)
        }
        for ticket in woken {
            guard let continuation = ticket.continuation else { continue }
            ticket.continuation = nil
            continuation.resume()
        }
    }

    private func leaveRoomQueue(_ ticket: RoomTicket) {
        let connectionId = ticket.key.connectionId
        roomQueues[connectionId]?.removeAll { $0 === ticket }
        if roomQueues[connectionId]?.isEmpty == true {
            roomQueues.removeValue(forKey: connectionId)
        }
        handRoom(on: connectionId)
    }

    private func parkForRoom(_ ticket: RoomTicket) async throws {
        try await withTaskCancellationHandler(
            operation: { try await parkUntilHanded(ticket) },
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.failRoomTicket(ticket)
                }
            }
        )
    }

    private func parkUntilHanded(_ ticket: RoomTicket) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled, !ticket.isWithdrawn else {
                continuation.resume(throwing: CancellationError())
                return
            }
            ticket.continuation = continuation
        }
    }

    private func failRoomTicket(_ ticket: RoomTicket) {
        guard let continuation = ticket.continuation else { return }
        ticket.continuation = nil
        continuation.resume(throwing: CancellationError())
    }

    // Same reason as `failTransportWaiters`: a parked caller would otherwise open what was just closed.
    private func withdrawRoomTickets(where matches: (UUID, String) -> Bool) {
        for line in roomQueues.values {
            for ticket in line where matches(ticket.key.connectionId, ticket.key.database) {
                ticket.isWithdrawn = true
                failRoomTicket(ticket)
            }
        }
    }

    /// Opens a second connection to the session's server, on `scope`'s database, through the
    /// transport the session already holds. Every tunnel manager closes its tunnel before building a
    /// new one, so dialing the session's effective endpoint is what keeps the other connections up.
    /// A database lane opens its user connection here too, as `.session`. `queryTimeoutSeconds`
    /// replaces the session's timeout, for a debug target that waits on a person between steps.
    internal static func openServerDriver(
        for scope: DatabaseScope,
        purpose: DriverPurpose,
        queryTimeoutSeconds: Int? = nil
    ) async throws -> DatabaseDriver {
        guard let session = DatabaseManager.shared.session(for: scope.connectionId) else {
            throw DatabaseError.notConnected
        }
        let queryTimeout = queryTimeoutSeconds ?? session.effectiveQueryTimeoutSeconds
        var connection = session.effectiveConnection ?? session.connection
        let plan = Self.planConnection(
            configuredDatabase: connection.database,
            targetDatabase: scope.database,
            authenticationIsDatabaseScoped: connection.type.authenticationIsDatabaseScoped,
            runsStartupCommands: DatabaseManager.hasStartupCommands(session.connection.startupCommands),
            switchesDatabaseWithoutReconnecting: PluginManager.shared
                .switchesDatabaseWithoutReconnecting(for: connection.type)
        )
        connection.database = plan.connectDatabase
        let preparedConfiguration = try await DatabaseDriverFactory.prepareConfiguration(
            for: connection,
            purpose: purpose
        )
        let deadline = ConnectionDeadline(configuredSeconds: session.connection.connectTimeoutSeconds)
        let timeoutEndpoint = ConnectionTimeoutEndpoint.database(session.connection.timeoutEndpointName)
        let operationTimeoutSeconds = session.effectiveQueryTimeoutSeconds > 0
            ? Double(session.effectiveQueryTimeoutSeconds)
            : nil

        let driver = try await DatabaseDriverFactory.createDriver(
            for: connection,
            passwordOverride: session.cachedPassword,
            awaitPlugins: true,
            purpose: purpose,
            deadline: deadline,
            timeoutEndpoint: timeoutEndpoint,
            effectiveQueryTimeoutSeconds: queryTimeout,
            preparedConfiguration: preparedConfiguration
        )
        do {
            try await driver.connect()
            let startupFailures = try await Self.prepareSession(
                driver,
                queryTimeoutSeconds: queryTimeout,
                startupCommands: session.connection.startupCommands,
                connectionName: session.connection.name,
                timeoutSeconds: operationTimeoutSeconds
            )
            DatabaseManager.shared.reportStartupFailures(startupFailures, for: scope.connectionId)
            if let database = plan.switchDatabase {
                try await Self.switchDatabase(driver, to: database, timeoutSeconds: operationTimeoutSeconds)
            }
            if let schema = scope.schema {
                try await Self.switchSchema(driver, to: schema, timeoutSeconds: operationTimeoutSeconds)
            }
        } catch {
            driver.disconnect()
            throw error
        }
        return driver
    }

    struct ConnectionPlan: Sendable, Equatable {
        let connectDatabase: String
        let switchDatabase: String?
    }

    /// A pooled entry is pinned once, at creation, and then answered from for up to the idle
    /// timeout, where the session driver is pinned again before every scoped operation. So anything
    /// that moves the connection between `connect` and the first read moves it for the entry's whole
    /// life, and the only thing that runs in between is the user's own startup commands. A `USE
    /// other` there leaves every unqualified read answering from `other` while the driver still
    /// reports the database it was asked for, which is how an unqualified `ALTER TABLE` from the
    /// structure editor reached the wrong one.
    ///
    /// Re-asserted only when there is something to undo and only where the engine takes a switch as
    /// a statement: an engine that reconnects to switch would throw away the startup commands it
    /// just ran, and one that cannot switch at all would fail a connection that works today. That is
    /// the same pair `pin(_:to:)` already trusts, so the pool issues no statement the session driver
    /// does not issue for the same scope.
    static func planConnection(
        configuredDatabase: String,
        targetDatabase: String,
        authenticationIsDatabaseScoped: Bool,
        runsStartupCommands: Bool = false,
        switchesDatabaseWithoutReconnecting: Bool = false
    ) -> ConnectionPlan {
        guard authenticationIsDatabaseScoped, targetDatabase != configuredDatabase else {
            let reassert = runsStartupCommands && switchesDatabaseWithoutReconnecting
                && !targetDatabase.isEmpty
            return ConnectionPlan(
                connectDatabase: targetDatabase, switchDatabase: reassert ? targetDatabase : nil
            )
        }
        return ConnectionPlan(connectDatabase: configuredDatabase, switchDatabase: targetDatabase)
    }

    static func switchDatabase(_ driver: DatabaseDriver, to database: String, timeoutSeconds: Double?) async throws {
        guard let adapter = driver as? PluginDriverAdapter else {
            throw DatabaseError.unsupportedOperation
        }
        try await bounded(
            driver: driver,
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: String(format: String(localized: "Switching to database '%@' timed out."), database)
        ) {
            try await adapter.switchDatabase(to: database)
        }
    }

    static func switchSchema(
        _ driver: DatabaseDriver,
        to schema: String,
        timeoutSeconds: Double?,
        unconditionally: Bool = false
    ) async throws {
        guard let switchable = driver as? SchemaSwitchable else { return }
        try await bounded(
            driver: driver,
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: String(format: String(localized: "Switching to schema '%@' timed out."), schema)
        ) {
            if unconditionally {
                try await switchable.switchSchema(to: schema)
            } else {
                try await switchable.switchSchemaIfNeeded(to: schema)
            }
        }
    }

    /// The startup commands are the user's own SQL and the query timeout can be a statement of its own,
    /// so neither belongs under the single-round-trip budget the other steps use. They still need a
    /// deadline: a hang here never resolves `pending[key]`, and a later reader joining that entry stays
    /// suspended with no error and no log line at all.
    static func prepareSession(
        _ driver: DatabaseDriver,
        queryTimeoutSeconds: Int,
        startupCommands: String?,
        connectionName: String,
        timeoutSeconds: Double?
    ) async throws -> [StartupCommandFailure] {
        try await bounded(
            driver: driver,
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: String(localized: "Preparing the metadata connection timed out.")
        ) {
            try? await driver.applyQueryTimeout(queryTimeoutSeconds)
            return await DatabaseManager.shared.executeStartupCommands(
                startupCommands, on: driver, connectionName: connectionName
            )
        }
    }

    /// Disconnects the driver when the deadline fires so a driver call that
    /// ignores task cancellation still completes and the timeout can propagate.
    private static func bounded<T: Sendable>(
        driver: DatabaseDriver,
        timeoutSeconds: Double?,
        timeoutMessage: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let timeoutSeconds, timeoutSeconds > 0 else {
            return try await operation()
        }
        do {
            return try await withTimeout(
                seconds: timeoutSeconds,
                onTimeout: { driver.disconnect() },
                operation: operation
            )
        } catch is TimeoutError {
            throw DatabaseError.connectionFailed(timeoutMessage)
        }
    }

    static func isStale(_ lastUsed: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastUsed) >= idleTimeout
    }

    /// Runs only while the pool is holding something, so an app with nothing pooled schedules
    /// nothing at all. One task for the whole pool rather than one per connection, because the
    /// pool is one map and a sweep reads all of it.
    private func startSweeperIfNeeded() {
        guard sweeper == nil, !entries.isEmpty else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sweepInterval)
                guard !Task.isCancelled else { return }
                self?.sweepIdleEntries()
            }
        }
    }

    private func stopSweeperIfEmpty() {
        guard entries.isEmpty, pending.isEmpty else { return }
        sweeper?.cancel()
        sweeper = nil
    }

    // An entry with work on it stays whatever its age: `lastUsed` is stamped when the work starts, so a long export
    // would otherwise have its own connection closed underneath it.
    internal func sweepIdleEntries(now: Date = Date()) {
        var sweptFrom: Set<UUID> = []
        for (key, list) in entries {
            for entry in list where entry.inFlightCount == 0 && Self.isStale(entry.lastUsed, now: now) {
                detach(entry, fromKey: key)
                entry.driver.disconnect()
                sweptFrom.insert(key.connectionId)
            }
        }
        for connectionId in sweptFrom {
            handRoom(on: connectionId)
        }
        stopSweeperIfEmpty()
    }

    // A caller with no room waits in `waitForRoom`, so only a lease taken inside another one's work opens past the limit.
    private func evictIdleIfNeeded(for connectionId: UUID) {
        guard heldCount(for: connectionId) >= Self.maxPerConnection else { return }
        evictLeastRecentlyUsedIdleEntry(for: connectionId)
    }

    // Bulk never takes the last place, so a completion read or a sidebar expand never waits behind a burst of bulk work.
    private func hasRoom(for workload: Workload, on connectionId: UUID) -> Bool {
        let placeIsFree = heldCount(for: connectionId) < Self.maxPerConnection
            || leastRecentlyUsedIdleEntry(for: connectionId) != nil
        guard workload == .bulk else { return placeIsFree }
        return placeIsFree && busyCount(for: connectionId) < Self.maxPerConnection - 1
    }

    private func pooled(on connectionId: UUID) -> [(key: Key, entry: Entry)] {
        var found: [(key: Key, entry: Entry)] = []
        for (key, list) in entries where key.connectionId == connectionId {
            found += list.map { (key: key, entry: $0) }
        }
        return found
    }

    // An open still dialing holds a place. One that landed holds it through its entry, and counts once.
    private func openingCount(for connectionId: UUID) -> Int {
        pending.filter { openKey, open in
            guard openKey.key.connectionId == connectionId else { return false }
            guard let landed = open.entry else { return true }
            return !isListed(landed, inKey: openKey.key)
        }.count
    }

    private func busyCount(for connectionId: UUID) -> Int {
        pooled(on: connectionId).filter { !isIdle($0.entry) }.count + openingCount(for: connectionId)
    }

    // Closing one idle entry per open, as the pool used to, left a burst's high-water mark standing until the idle
    // sweep: a tree Refresh across many databases held every connection it opened for ten minutes (#3103).
    private func trimIdleEntries(for connectionId: UUID) {
        while heldCount(for: connectionId) > Self.maxPerConnection {
            guard evictLeastRecentlyUsedIdleEntry(for: connectionId) else { break }
        }
        stopSweeperIfEmpty()
    }

    private func heldCount(for connectionId: UUID) -> Int {
        pooled(on: connectionId).count + openingCount(for: connectionId)
    }

    @discardableResult
    private func evictLeastRecentlyUsedIdleEntry(for connectionId: UUID) -> Bool {
        guard let victim = leastRecentlyUsedIdleEntry(for: connectionId),
              detach(victim.entry, fromKey: victim.key)
        else { return false }
        victim.entry.driver.disconnect()
        return true
    }

    private func leastRecentlyUsedIdleEntry(for connectionId: UUID) -> (key: Key, entry: Entry)? {
        pooled(on: connectionId)
            .filter { isIdle($0.entry) }
            .min { $0.entry.lastUsed < $1.entry.lastUsed }
    }
}
