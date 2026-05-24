//
//  CloudflareTunnelManager.swift
//  TablePro
//
//  Manages cloudflared Access TCP tunnel lifecycle for database connections.
//

import Darwin
import Foundation
import Network
import os

actor CloudflareTunnelManager {
    static let shared = CloudflareTunnelManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudflareTunnelManager")

    private static let readinessTimeout: TimeInterval = 30
    private static let readinessPollInterval: UInt64 = 250_000_000
    private static let portRetryCount = 5
    private static let stalePidsDefaultsKey = "cloudflaredStalePids"

    private struct TunnelState {
        let runner: any CloudflaredRunner
        let localPort: Int
    }

    private var tunnels: [UUID: TunnelState] = [:]
    private var pidRecords: [UUID: CloudflaredPidRecord] = [:]
    private let runnerFactory: () -> any CloudflaredRunner

    /// Static registry for synchronous termination during app shutdown.
    private static let runnerRegistry = OSAllocatedUnfairLock(initialState: [UUID: any CloudflaredRunner]())

    /// Prevents App Nap from throttling the supervised process while tunnels are active.
    private var appNapActivity: NSObjectProtocol?

    init(runnerFactory: @escaping () -> any CloudflaredRunner = { ProcessCloudflaredRunner() }) {
        self.runnerFactory = runnerFactory
    }

    /// Create a Cloudflare Access TCP tunnel for a database connection.
    /// Returns the local loopback port the database driver should connect to.
    func createTunnel(
        connectionId: UUID,
        config: CloudflareConfiguration,
        tokenId: String? = nil,
        tokenSecret: String? = nil
    ) async throws -> Int {
        if tunnels[connectionId] != nil {
            try await closeTunnel(connectionId: connectionId)
        }

        let binaryPath = try resolveBinaryPath(config: config)
        let environment = Self.buildEnvironment(config: config, tokenId: tokenId, tokenSecret: tokenSecret)
        let listenHost = config.exposeToLAN ? "0.0.0.0" : "127.0.0.1"
        let attempts = config.localPort != nil ? 1 : Self.portRetryCount

        var lastError: Error = CloudflareTunnelError.noAvailablePort
        for _ in 0..<attempts {
            let port = try config.localPort ?? allocateFreePort()
            let runner = runnerFactory()
            let arguments = [
                "access", "tcp",
                "--hostname", config.accessHostname,
                "--url", "\(listenHost):\(port)"
            ]

            do {
                try runner.start(binaryPath: binaryPath, arguments: arguments, environment: environment)
            } catch {
                throw CloudflareTunnelError.binaryNotFound
            }

            do {
                try await awaitReadiness(runner: runner, port: port)
            } catch let error as CloudflareTunnelError {
                runner.stop()
                if case .startupFailed(let tail) = error, config.localPort == nil, Self.isPortInUse(tail) {
                    Self.logger.notice("cloudflared port \(port) in use, retrying with another")
                    lastError = CloudflareTunnelError.noAvailablePort
                    continue
                }
                throw error
            }

            register(connectionId: connectionId, runner: runner, port: port, binaryPath: binaryPath)
            Self.logger.info("Cloudflare tunnel ready for \(connectionId.uuidString, privacy: .public) on 127.0.0.1:\(port)")
            return port
        }

        throw lastError
    }

    func closeTunnel(connectionId: UUID) async throws {
        guard let state = tunnels.removeValue(forKey: connectionId) else { return }
        Self.runnerRegistry.withLock { $0[connectionId] = nil }
        pidRecords.removeValue(forKey: connectionId)
        persistPidRecords()
        updateAppNapState()
        state.runner.stop()
    }

    func closeAllTunnels() async {
        let current = tunnels
        tunnels.removeAll()
        pidRecords.removeAll()
        persistPidRecords()
        Self.runnerRegistry.withLock { $0.removeAll() }
        updateAppNapState()
        for (_, state) in current {
            state.runner.stop()
        }
    }

    /// Synchronously terminate all cloudflared processes.
    /// Called from `applicationWillTerminate` where async is not available.
    nonisolated func terminateAllProcessesSync() {
        let runners = Self.runnerRegistry.withLock { dict -> [any CloudflaredRunner] in
            let values = Array(dict.values)
            dict.removeAll()
            return values
        }
        for runner in runners {
            runner.stop()
        }
    }

    func hasTunnel(connectionId: UUID) -> Bool {
        tunnels[connectionId] != nil
    }

    func getLocalPort(connectionId: UUID) -> Int? {
        tunnels[connectionId]?.localPort
    }

    /// Reap cloudflared processes left running by a previous session that crashed
    /// or was force-quit. Verifies each recorded PID still points at cloudflared
    /// before signalling it, so a recycled PID is never killed.
    func sweepStalePidsIfNeeded() {
        defer { UserDefaults.standard.removeObject(forKey: Self.stalePidsDefaultsKey) }
        guard let data = UserDefaults.standard.data(forKey: Self.stalePidsDefaultsKey),
              let records = try? JSONDecoder().decode([CloudflaredPidRecord].self, from: data) else {
            return
        }
        for record in records where Self.isLiveCloudflared(record) {
            kill(record.pid, SIGTERM)
            Self.logger.notice("Reaped stale cloudflared pid \(record.pid)")
        }
    }

    // MARK: - Private: lifecycle

    private func register(connectionId: UUID, runner: any CloudflaredRunner, port: Int, binaryPath: String) {
        tunnels[connectionId] = TunnelState(runner: runner, localPort: port)
        Self.runnerRegistry.withLock { $0[connectionId] = runner }
        if let pid = runner.processIdentifier {
            pidRecords[connectionId] = CloudflaredPidRecord(pid: pid, binaryPath: binaryPath)
            persistPidRecords()
        }
        updateAppNapState()
        startDeathWatch(connectionId: connectionId, runner: runner)
    }

    private func startDeathWatch(connectionId: UUID, runner: any CloudflaredRunner) {
        Task { [weak self] in
            let result = await runner.termination
            await self?.handleTermination(connectionId: connectionId, result: result)
        }
    }

    private func handleTermination(connectionId: UUID, result: CloudflaredTermination) async {
        guard tunnels.removeValue(forKey: connectionId) != nil else { return }
        Self.runnerRegistry.withLock { $0[connectionId] = nil }
        pidRecords.removeValue(forKey: connectionId)
        persistPidRecords()
        updateAppNapState()
        guard !result.wasRequested else { return }
        Self.logger.warning("Cloudflare tunnel died for connection \(connectionId.uuidString, privacy: .public)")
        await DatabaseManager.shared.handleCloudflareTunnelDied(connectionId: connectionId)
    }

    // MARK: - Private: readiness

    private func awaitReadiness(runner: any CloudflaredRunner, port: Int) async throws {
        let monitor = CloudflaredStartupMonitor()
        let stderrTask = Task {
            for await line in runner.stderrLines {
                await monitor.append(line)
            }
            await monitor.markStreamEnded()
        }
        defer { stderrTask.cancel() }

        // The stderr scan is load-bearing: cloudflared may accept the local port
        // before it has authenticated, so a passing TCP probe alone can't tell a
        // ready tunnel from one waiting on browser sign-in. Keep checking both.
        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        while Date() < deadline {
            if let url = await monitor.browserAuthURL {
                throw CloudflareTunnelError.browserAuthRequired(url: url)
            }
            if await monitor.streamEnded {
                throw CloudflareTunnelError.startupFailed(stderrTail: await monitor.tail)
            }
            if await Self.canConnect(host: "127.0.0.1", port: port) {
                if let url = await monitor.browserAuthURL {
                    throw CloudflareTunnelError.browserAuthRequired(url: url)
                }
                return
            }
            try await Task.sleep(nanoseconds: Self.readinessPollInterval)
        }
        throw CloudflareTunnelError.readinessTimeout(stderrTail: await monitor.tail)
    }

    private static func canConnect(host: String, port: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let complete: (Bool) -> Void = { value in
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard shouldResume else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    complete(true)
                case .failed, .cancelled, .waiting:
                    complete(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    // MARK: - Private: binary, environment, port

    private func resolveBinaryPath(config: CloudflareConfiguration) throws -> String {
        if !config.binaryPath.isEmpty {
            let expandedPath = (config.binaryPath as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: expandedPath) else {
                throw CloudflareTunnelError.binaryNotFound
            }
            return expandedPath
        }
        guard let resolved = CLIExecutableFinder.findExecutable("cloudflared") else {
            throw CloudflareTunnelError.binaryNotFound
        }
        return resolved
    }

    private static func buildEnvironment(
        config: CloudflareConfiguration,
        tokenId: String?,
        tokenSecret: String?
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        guard config.authMethod == .serviceToken else { return environment }
        if let tokenId, !tokenId.isEmpty {
            environment["TUNNEL_SERVICE_TOKEN_ID"] = tokenId
        }
        if let tokenSecret, !tokenSecret.isEmpty {
            environment["TUNNEL_SERVICE_TOKEN_SECRET"] = tokenSecret
        }
        return environment
    }

    private func allocateFreePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CloudflareTunnelError.noAvailablePort }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw CloudflareTunnelError.noAvailablePort }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw CloudflareTunnelError.noAvailablePort }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    // MARK: - Private: stale PID persistence

    private func persistPidRecords() {
        let records = Array(pidRecords.values)
        guard !records.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.stalePidsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.stalePidsDefaultsKey)
    }

    private static func isLiveCloudflared(_ record: CloudflaredPidRecord) -> Bool {
        guard record.pid > 0 else { return false }
        let pathBufferSize = 4 * Int(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let length = proc_pidpath(record.pid, &buffer, UInt32(pathBufferSize))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        if !record.binaryPath.isEmpty, path == record.binaryPath { return true }
        return (path as NSString).lastPathComponent == "cloudflared"
    }

    private static func isPortInUse(_ stderrTail: String) -> Bool {
        stderrTail.lowercased().contains("address already in use")
    }

    // MARK: - Private: App Nap

    private func updateAppNapState() {
        if !tunnels.isEmpty, appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Cloudflare tunnel process requires timely execution"
            )
        } else if tunnels.isEmpty, let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }
}

// MARK: - PID record

struct CloudflaredPidRecord: Codable, Sendable, Equatable {
    let pid: Int32
    let binaryPath: String
}

// MARK: - Startup monitor

/// Accumulates cloudflared stderr during startup so the manager can detect a
/// browser sign-in prompt, surface an error tail, and notice an early exit.
private actor CloudflaredStartupMonitor {
    private(set) var tail = ""
    private(set) var browserAuthURL: String?
    private(set) var streamEnded = false
    private let tailCap = 2_000

    func append(_ line: String) {
        if browserAuthURL == nil, let url = Self.extractBrowserAuthURL(from: line) {
            browserAuthURL = url
        }
        tail += line + "\n"
        if tail.count > tailCap {
            tail = String(tail.suffix(tailCap))
        }
    }

    func markStreamEnded() {
        streamEnded = true
    }

    private static func extractBrowserAuthURL(from line: String) -> String? {
        let lowercased = line.lowercased()
        guard lowercased.contains("/cdn-cgi/access/") || lowercased.contains("browser window should have opened") else {
            return nil
        }
        guard let range = line.range(of: "https://") else { return nil }
        let token = line[range.lowerBound...].split { $0 == " " || $0 == "\"" || $0 == "\t" }.first
        return token.map(String.init)
    }
}
