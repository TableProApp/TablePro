//
//  CloudSQLProxyManager.swift
//  TablePro
//

import Darwin
import Foundation
import os

actor CloudSQLProxyManager: TunnelManaging {
    static let shared = CloudSQLProxyManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudSQLProxyManager")

    private static let readinessTimeout: TimeInterval = 30
    private static let readinessPollInterval: UInt64 = 250_000_000
    private static let portRetryCount = 5
    private static let stalePidsDefaultsKey = "cloudSQLProxyStalePids"
    private static let credentialsFilePrefix = "com.TablePro.cloudsqlproxy."

    private struct TunnelState {
        let runner: any SupervisedProcessRunner
        let localPort: Int
        let credentialsFilePath: String?
    }

    private var tunnels: [UUID: TunnelState] = [:]
    private var pidRecords: [UUID: CloudSQLProxyPidRecord] = [:]
    private let runnerFactory: () -> any SupervisedProcessRunner

    private static let runnerRegistry = OSAllocatedUnfairLock(initialState: [UUID: any SupervisedProcessRunner]())

    private var appNapActivity: NSObjectProtocol?

    init(runnerFactory: @escaping () -> any SupervisedProcessRunner = { ProcessSupervisedRunner() }) {
        self.runnerFactory = runnerFactory
    }

    func createTunnel(
        connectionId: UUID,
        config: CloudSQLProxyConfiguration,
        serviceAccountKeyJSON: String? = nil
    ) async throws -> Int {
        guard config.isValid else { throw CloudSQLProxyError.invalidInstanceConnectionName }

        if tunnels[connectionId] != nil {
            try await closeTunnel(connectionId: connectionId)
        }

        let binaryPath = try await resolveBinaryPath(config: config)
        let credentialsFilePath = try writeCredentialsFileIfNeeded(
            connectionId: connectionId,
            config: config,
            serviceAccountKeyJSON: serviceAccountKeyJSON
        )
        let environment = ProcessInfo.processInfo.environment
        let attempts = config.localPort != nil ? 1 : Self.portRetryCount

        var lastError: Error = CloudSQLProxyError.noAvailablePort
        for _ in 0..<attempts {
            guard let port = config.localPort ?? LoopbackPort.allocateFree() else {
                throw CloudSQLProxyError.noAvailablePort
            }
            let runner = runnerFactory()
            let arguments = Self.buildArguments(config: config, port: port, credentialsFilePath: credentialsFilePath)

            do {
                try runner.start(binaryPath: binaryPath, arguments: arguments, environment: environment)
            } catch {
                deleteCredentialsFile(at: credentialsFilePath)
                throw CloudSQLProxyError.binaryNotFound
            }

            do {
                try await awaitReadiness(runner: runner, port: port)
            } catch let error as CloudSQLProxyError {
                runner.stop()
                if case .startupFailed(let tail) = error, config.localPort == nil, Self.isPortInUse(tail) {
                    Self.logger.notice("cloud-sql-proxy port \(port) in use, retrying with another")
                    lastError = CloudSQLProxyError.noAvailablePort
                    continue
                }
                deleteCredentialsFile(at: credentialsFilePath)
                throw error
            }

            register(
                connectionId: connectionId,
                runner: runner,
                port: port,
                binaryPath: binaryPath,
                credentialsFilePath: credentialsFilePath
            )
            Self.logger.info("Cloud SQL Auth Proxy ready for \(connectionId.uuidString, privacy: .public) on 127.0.0.1:\(port)")
            return port
        }

        deleteCredentialsFile(at: credentialsFilePath)
        throw lastError
    }

    func closeTunnel(connectionId: UUID) async throws {
        guard let state = tunnels.removeValue(forKey: connectionId) else { return }
        Self.runnerRegistry.withLock { $0[connectionId] = nil }
        pidRecords.removeValue(forKey: connectionId)
        persistPidRecords()
        updateAppNapState()
        state.runner.stop()
        deleteCredentialsFile(at: state.credentialsFilePath)
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
            deleteCredentialsFile(at: state.credentialsFilePath)
        }
    }

    nonisolated func terminateAllProcessesSync() {
        let runners = Self.runnerRegistry.withLock { dict -> [any SupervisedProcessRunner] in
            let values = Array(dict.values)
            dict.removeAll()
            return values
        }
        for runner in runners {
            runner.stop()
        }
        Self.purgeCredentialsFiles()
    }

    func hasTunnel(connectionId: UUID) -> Bool {
        tunnels[connectionId] != nil
    }

    func getLocalPort(connectionId: UUID) -> Int? {
        tunnels[connectionId]?.localPort
    }

    func sweepStalePidsIfNeeded() {
        Self.purgeCredentialsFiles()
        defer { UserDefaults.standard.removeObject(forKey: Self.stalePidsDefaultsKey) }
        guard let data = UserDefaults.standard.data(forKey: Self.stalePidsDefaultsKey),
              let records = try? JSONDecoder().decode([CloudSQLProxyPidRecord].self, from: data) else {
            return
        }
        for record in records where Self.isLiveCloudSQLProxy(record) {
            kill(record.pid, SIGTERM)
            Self.logger.notice("Reaped stale cloud-sql-proxy pid \(record.pid)")
        }
    }

    // MARK: - Private: lifecycle

    private func register(
        connectionId: UUID,
        runner: any SupervisedProcessRunner,
        port: Int,
        binaryPath: String,
        credentialsFilePath: String?
    ) {
        tunnels[connectionId] = TunnelState(runner: runner, localPort: port, credentialsFilePath: credentialsFilePath)
        Self.runnerRegistry.withLock { $0[connectionId] = runner }
        if let pid = runner.processIdentifier {
            pidRecords[connectionId] = CloudSQLProxyPidRecord(pid: pid, binaryPath: binaryPath)
            persistPidRecords()
        }
        updateAppNapState()
        startDeathWatch(connectionId: connectionId, runner: runner)
    }

    private func startDeathWatch(connectionId: UUID, runner: any SupervisedProcessRunner) {
        Task { [weak self] in
            let result = await runner.termination
            await self?.handleTermination(connectionId: connectionId, result: result)
        }
    }

    private func handleTermination(connectionId: UUID, result: SubprocessTermination) async {
        guard let state = tunnels.removeValue(forKey: connectionId) else { return }
        Self.runnerRegistry.withLock { $0[connectionId] = nil }
        pidRecords.removeValue(forKey: connectionId)
        persistPidRecords()
        updateAppNapState()
        deleteCredentialsFile(at: state.credentialsFilePath)
        guard !result.wasRequested else { return }
        Self.logger.warning("Cloud SQL Auth Proxy died for connection \(connectionId.uuidString, privacy: .public)")
        await DatabaseManager.shared.handleCloudSQLProxyTunnelDied(connectionId: connectionId)
    }

    // MARK: - Private: readiness

    private func awaitReadiness(runner: any SupervisedProcessRunner, port: Int) async throws {
        let monitor = CloudSQLProxyStartupMonitor()
        let stderrTask = Task {
            for await line in runner.stderrLines {
                await monitor.append(line)
            }
            await monitor.markStreamEnded()
        }
        defer { stderrTask.cancel() }

        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        while Date() < deadline {
            if await monitor.streamEnded {
                throw CloudSQLProxyError.startupFailed(stderrTail: await monitor.tail)
            }
            if await LoopbackPort.isReachable(host: "127.0.0.1", port: port) {
                return
            }
            try await Task.sleep(nanoseconds: Self.readinessPollInterval)
        }
        throw CloudSQLProxyError.readinessTimeout(stderrTail: await monitor.tail)
    }

    // MARK: - Private: binary, arguments, credentials

    private func resolveBinaryPath(config: CloudSQLProxyConfiguration) async throws -> String {
        if !config.binaryPath.isEmpty {
            let expandedPath = (config.binaryPath as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: expandedPath) else {
                throw CloudSQLProxyError.binaryNotFound
            }
            return expandedPath
        }
        if let resolved = CLIExecutableFinder.findExecutable("cloud-sql-proxy") {
            return resolved
        }
        if let cached = await CloudSQLProxyBinaryManager.shared.cachedBinaryPath {
            return cached
        }
        throw CloudSQLProxyError.binaryNotFound
    }

    private static func buildArguments(
        config: CloudSQLProxyConfiguration,
        port: Int,
        credentialsFilePath: String?
    ) -> [String] {
        var arguments = ["--port", "\(port)", "--address", "127.0.0.1"]
        if let credentialsFilePath {
            arguments += ["--credentials-file", credentialsFilePath]
        }
        if config.useIAMAuth {
            arguments.append("--auto-iam-authn")
        }
        if config.usePrivateIP {
            arguments.append("--private-ip")
        }
        arguments.append(config.instanceConnectionName)
        return arguments
    }

    private func writeCredentialsFileIfNeeded(
        connectionId: UUID,
        config: CloudSQLProxyConfiguration,
        serviceAccountKeyJSON: String?
    ) throws -> String? {
        guard config.authMode == .serviceAccountKey else { return nil }
        guard let json = serviceAccountKeyJSON, !json.isEmpty, let data = json.data(using: .utf8) else {
            throw CloudSQLProxyError.credentialsWriteFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.credentialsFilePrefix)\(connectionId.uuidString).json")
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw CloudSQLProxyError.credentialsWriteFailed
        }
        return url.path
    }

    private func deleteCredentialsFile(at path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func purgeCredentialsFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in entries
        where url.lastPathComponent.hasPrefix(credentialsFilePrefix) && url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private: stale PID persistence

    private func persistPidRecords() {
        let records = Array(pidRecords.values)
        guard !records.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.stalePidsDefaultsKey)
            return
        }
        do {
            let data = try JSONEncoder().encode(records)
            UserDefaults.standard.set(data, forKey: Self.stalePidsDefaultsKey)
        } catch {
            Self.logger.error("Failed to persist cloud-sql-proxy PID records: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func isLiveCloudSQLProxy(_ record: CloudSQLProxyPidRecord) -> Bool {
        guard record.pid > 0 else { return false }
        let pathBufferSize = 4 * Int(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let length = proc_pidpath(record.pid, &buffer, UInt32(pathBufferSize))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        if !record.binaryPath.isEmpty, path == record.binaryPath { return true }
        return (path as NSString).lastPathComponent == "cloud-sql-proxy"
    }

    private static func isPortInUse(_ stderrTail: String) -> Bool {
        stderrTail.lowercased().contains("address already in use")
    }

    // MARK: - Private: App Nap

    private func updateAppNapState() {
        if !tunnels.isEmpty, appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Cloud SQL Auth Proxy process requires timely execution"
            )
        } else if tunnels.isEmpty, let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }
}

// MARK: - PID record

struct CloudSQLProxyPidRecord: Codable, Sendable, Equatable {
    let pid: Int32
    let binaryPath: String
}

// MARK: - Startup monitor

private actor CloudSQLProxyStartupMonitor {
    private(set) var tail = ""
    private(set) var streamEnded = false
    private let tailCap = 2_000

    func append(_ line: String) {
        tail += line + "\n"
        if tail.count > tailCap {
            tail = String(tail.suffix(tailCap))
        }
    }

    func markStreamEnded() {
        streamEnded = true
    }
}
