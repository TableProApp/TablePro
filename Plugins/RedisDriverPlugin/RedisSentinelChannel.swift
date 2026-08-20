//
//  RedisSentinelChannel.swift
//  RedisDriverPlugin
//
//  A single-node channel that asks Sentinel where the primary is, and keeps asking.
//
//  Failover cannot be detected from the data connection. Measured against Redis 8.10.1: for
//  several seconds after `SENTINEL failover` the demoted node still reports `role:master` and
//  still answers writes with +OK, and those writes are then gone. No -READONLY ever arrives.
//  The only signal that moves in time is the quorum's own answer, so the address is re-checked
//  on every health-monitor ping rather than inferred from what the node says about itself.
//

import Foundation
import OSLog
import TableProPluginKit

private let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisSentinelChannel")

final class RedisSentinelChannel: RedisCommandChannel, @unchecked Sendable {
    private let resolver: RedisSentinelResolver
    private let group: String
    private let username: String?
    private let password: String?
    private let database: Int
    private let sslConfig: SSLConfiguration

    private let lock = NSLock()
    private var connection: RedisPluginConnection?
    private var primary: RedisNodeAddress?
    private var isShuttingDown = false

    init(
        resolver: RedisSentinelResolver,
        group: String,
        username: String?,
        password: String?,
        database: Int,
        sslConfig: SSLConfiguration
    ) {
        self.resolver = resolver
        self.group = group
        self.username = username
        self.password = password
        self.database = database
        self.sslConfig = sslConfig
    }

    var isConnected: Bool { current?.isConnected ?? false }

    private var current: RedisPluginConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }

    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {
        report(.custom(String(localized: "Asking Sentinel for the primary")))
        let resolution = try await resolvePrimary()
        try await open(resolution.primary, reportingStage: report)
        logger.info(
            "Sentinel group \(self.group, privacy: .public) resolved to \(resolution.primary.identifier, privacy: .public)"
        )
    }

    func disconnect() {
        lock.lock()
        isShuttingDown = true
        let existing = connection
        connection = nil
        primary = nil
        lock.unlock()
        existing?.disconnect()
    }

    func cancelCurrentQuery() {
        current?.cancelCurrentQuery()
    }

    func serverVersion() -> String? { current?.serverVersion() }

    func currentDatabase() -> Int { current?.currentDatabase() ?? database }

    func executeCommand(_ args: [Data]) async throws -> RedisReply {
        try await withFailoverRetry(isReplayable: { replayable($0, ifReadOnly: args) }) {
            try await $0.executeCommand(args)
        }
    }

    func executePipeline(_ commands: [[Data]]) async throws -> [RedisReply] {
        try await withFailoverRetry(
            isReplayable: { failure in
                !failure.wasDelivered || commands.allSatisfy { replayable(failure, ifReadOnly: $0) }
            }
        ) {
            try await $0.executePipeline(commands)
        }
    }

    func selectDatabase(_ index: Int) async throws {
        try await withFailoverRetry(isReplayable: { _ in true }) { try await $0.selectDatabase(index) }
    }

    /// Re-asks the quorum and re-points the connection when the primary has moved. Called from the
    /// driver's ping, which the health monitor runs every 30 seconds.
    func verifyStillPrimary() async throws {
        let resolution = try await resolvePrimary()
        guard !isPointing(at: resolution.primary) else { return }
        logger.warning(
            "Sentinel moved primary for \(self.group, privacy: .public) to \(resolution.primary.identifier, privacy: .public)"
        )
        try await open(resolution.primary, reportingStage: { _ in })
    }

    private func isPointing(at address: RedisNodeAddress) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return primary == address && connection != nil
    }

    private func adopt(_ opened: RedisPluginConnection, at address: RedisNodeAddress) -> RedisPluginConnection?? {
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown else { return nil }
        let previous = connection
        connection = opened
        primary = address
        return .some(previous)
    }

    private var isTearingDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isShuttingDown
    }

    private func resolvePrimary() async throws -> RedisSentinelResolution {
        do {
            return try await resolver.resolvePrimary()
        } catch let error as RedisSentinelError {
            throw RedisSentinelErrorPresenter.pluginError(error)
        }
    }

    private func open(_ address: RedisNodeAddress, reportingStage report: @escaping ConnectionStageReporter) async throws {
        let opened = RedisPluginConnection(
            host: address.host,
            port: address.port,
            username: username,
            password: password,
            database: database,
            sslConfig: sslConfig
        )
        try await opened.connect(reportingStage: report)

        guard let previous = adopt(opened, at: address) else {
            opened.disconnect()
            throw RedisPluginError.notConnected
        }
        previous?.disconnect()
    }

    /// Runs the work, and on a lost connection re-resolves before trying once more. Only one
    /// retry: a quorum that keeps handing back a dead address is a real failure, not a race.
    ///
    /// `isReplayable` carries the same rule the connection layer applies, because re-pointing at a
    /// new primary does not make a delivered write safe to send twice. Without it this layer would
    /// undo the fix below it and run an INCR again after a read timed out.
    private func withFailoverRetry<T>(
        isReplayable: (RedisTransportFailure) -> Bool,
        _ work: (RedisPluginConnection) async throws -> T
    ) async throws -> T {
        guard let connection = current else { throw RedisPluginError.notConnected }
        do {
            return try await work(connection)
        } catch let failure as RedisTransportFailure {
            guard !isTearingDown, isReplayable(failure) else { throw failure }
            let resolution = try await resolvePrimary()
            try await open(resolution.primary, reportingStage: { _ in })
            guard let reconnected = current else { throw failure }
            return try await work(reconnected)
        }
    }

    private func replayable(_ failure: RedisTransportFailure, ifReadOnly args: [Data]) -> Bool {
        guard failure.wasDelivered else { return true }
        return (current?.routing ?? RedisCommandRouting()).isReadOnly(args)
    }
}
