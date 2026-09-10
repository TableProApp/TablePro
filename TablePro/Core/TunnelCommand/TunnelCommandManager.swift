//
//  TunnelCommandManager.swift
//  TablePro
//

import Darwin
import Foundation
import os

/// Runs the process that forwards a local port to the database, and holds it for the life of the
/// connection.
///
/// The subprocess shape is the one `CloudSQLProxyManager` established: allocate a loopback port,
/// start the process, wait for the port to answer or for the process to give up, then watch it so
/// a death becomes a reconnect rather than a session that quietly stops working.
actor TunnelCommandManager: TunnelManaging {
    static let shared = TunnelCommandManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "TunnelCommandManager")

    private static let readinessTimeout: TimeInterval = 30
    private static let readinessPollInterval: UInt64 = 250_000_000
    private static let portRetryCount = 5
    private static let stalePidsDefaultsKey = "tunnelCommandStalePids"

    private struct TunnelState {
        let runner: any SupervisedProcessRunner
        let localPort: Int
    }

    private var tunnels: [UUID: TunnelState] = [:]
    private var pidRecords: [UUID: TunnelCommandPidRecord] = [:]
    private let runnerFactory: () -> any SupervisedProcessRunner
    private let executableLookup: (String) -> String?
    private var staleSweep: Task<Void, Never>?
    private let reaperTimings: StaleProcessReaper.Timings

    private static let runnerRegistry = OSAllocatedUnfairLock(initialState: [UUID: any SupervisedProcessRunner]())

    private var appNapActivity: NSObjectProtocol?

    init(
        runnerFactory: @escaping () -> any SupervisedProcessRunner = { ProcessSupervisedRunner() },
        executableLookup: @escaping (String) -> String? = { CLIExecutableFinder.findExecutable($0) },
        reaperTimings: StaleProcessReaper.Timings = .production
    ) {
        self.runnerFactory = runnerFactory
        self.executableLookup = executableLookup
        self.reaperTimings = reaperTimings
    }

    func createTunnel(
        connectionId: UUID,
        config: TunnelCommandConfiguration,
        remoteHost: String,
        remotePort: Int
    ) async throws -> Int {
        await sweepStalePidsIfNeeded()

        if tunnels[connectionId] != nil {
            try await closeTunnel(connectionId: connectionId)
        }

        let environment = CLIToolEnvironment.augmented()
        var lastError: Error = TunnelCommandError.noAvailablePort

        for _ in 0..<Self.portRetryCount {
            guard let port = LoopbackPort.allocateFree() else {
                throw TunnelCommandError.noAvailablePort
            }
            let invocation = try TunnelCommandBuilder.invocation(
                for: config,
                localPort: port,
                remoteHost: remoteHost,
                remotePort: remotePort
            )
            let binaryPath = try resolveExecutablePath(invocation.executable)
            let runner = runnerFactory()

            do {
                try runner.start(
                    binaryPath: binaryPath,
                    arguments: invocation.arguments,
                    environment: environment
                )
            } catch {
                throw TunnelCommandError.executableNotFound(invocation.executable)
            }

            /// Every exit from here stops the process, cancellation included. A connect the user
            /// cancels while the port is still being waited on would otherwise leave the forward
            /// running until the next launch swept it, still holding its port.
            do {
                try await awaitReadiness(runner: runner, port: port)
            } catch {
                runner.stop()
                if let commandError = error as? TunnelCommandError,
                   case .startupFailed(let tail) = commandError,
                   Self.isPortInUse(tail) {
                    Self.logger.notice("Tunnel command port \(port) in use, retrying with another")
                    lastError = TunnelCommandError.noAvailablePort
                    continue
                }
                throw error
            }

            register(
                connectionId: connectionId,
                runner: runner,
                port: port,
                binaryPath: binaryPath,
                executableName: (binaryPath as NSString).lastPathComponent
            )
            Self.logger.info(
                "Tunnel command ready for \(connectionId.uuidString, privacy: .public) on 127.0.0.1:\(port)"
            )
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

    nonisolated func terminateAllProcessesSync() {
        let runners = Self.runnerRegistry.withLock { dict -> [any SupervisedProcessRunner] in
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

    /// Runs at most once per process, and `createTunnel` awaits it so a forward a crashed session
    /// left behind has released its port before a replacement asks for one.
    func sweepStalePidsIfNeeded() async {
        if let staleSweep {
            await staleSweep.value
            return
        }
        let task = Task { await self.performStaleSweep() }
        staleSweep = task
        await task.value
    }

    private func performStaleSweep() async {
        let defaults = AppStorageEnvironment.shared.defaults
        guard let data = defaults.data(forKey: Self.stalePidsDefaultsKey),
              let records = try? JSONDecoder().decode([TunnelCommandPidRecord].self, from: data) else {
            defaults.removeObject(forKey: Self.stalePidsDefaultsKey)
            return
        }

        let survivors = await StaleProcessReaper.reap(
            records.map { $0.reaperTarget },
            timings: reaperTimings,
            signal: Self.signalProcessGroup
        )

        guard !survivors.isEmpty else {
            defaults.removeObject(forKey: Self.stalePidsDefaultsKey)
            return
        }
        let surviving = Set(survivors.map(\.pid))
        let kept = records.filter { surviving.contains($0.pid) }
        if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: Self.stalePidsDefaultsKey)
        }
    }

    /// A forwarding command can outlive its own process: `aws ssm start-session` runs
    /// `session-manager-plugin` beside it, and that is what actually holds the port. Every child
    /// inherits the process group Foundation gives the command, so the group is what has to go.
    nonisolated private static func signalProcessGroup(_ pid: pid_t, _ signalNumber: Int32) {
        guard pid > 1 else { return }
        if kill(-pid, signalNumber) != 0 {
            kill(pid, signalNumber)
        }
    }

    // MARK: - Private: lifecycle

    private func register(
        connectionId: UUID,
        runner: any SupervisedProcessRunner,
        port: Int,
        binaryPath: String,
        executableName: String
    ) {
        tunnels[connectionId] = TunnelState(runner: runner, localPort: port)
        Self.runnerRegistry.withLock { $0[connectionId] = runner }
        if let pid = runner.processIdentifier {
            pidRecords[connectionId] = TunnelCommandPidRecord(
                pid: pid,
                binaryPath: binaryPath,
                executableName: executableName
            )
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
        guard tunnels.removeValue(forKey: connectionId) != nil else { return }
        Self.runnerRegistry.withLock { $0[connectionId] = nil }
        pidRecords.removeValue(forKey: connectionId)
        persistPidRecords()
        updateAppNapState()
        guard !result.wasRequested else { return }
        Self.logger.warning("Tunnel command died for connection \(connectionId.uuidString, privacy: .public)")
        await DatabaseManager.shared.handleTunnelCommandDied(connectionId: connectionId)
    }

    // MARK: - Private: readiness

    private func awaitReadiness(runner: any SupervisedProcessRunner, port: Int) async throws {
        let monitor = TunnelCommandStartupMonitor()
        let stderrTask = Task {
            for await line in runner.stderrLines {
                await monitor.append(line)
            }
            await monitor.markStreamEnded()
        }
        defer { stderrTask.cancel() }

        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        while Date() < deadline {
            if await LoopbackPort.isReachable(host: "127.0.0.1", port: port) {
                return
            }
            if await monitor.streamEnded {
                throw TunnelCommandError.startupFailed(stderrTail: await monitor.tail)
            }
            try await Task.sleep(nanoseconds: Self.readinessPollInterval)
        }
        throw TunnelCommandError.readinessTimeout(stderrTail: await monitor.tail)
    }

    // MARK: - Private: executable

    private func resolveExecutablePath(_ executable: String) throws -> String {
        guard !executable.isEmpty else { throw TunnelCommandError.commandEmpty }
        if executable.contains("/") {
            let expanded = (executable as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: expanded) else {
                throw TunnelCommandError.executableNotFound(executable)
            }
            return expanded
        }
        guard let resolved = executableLookup(executable) else {
            throw TunnelCommandError.executableNotFound(executable)
        }
        return resolved
    }

    // MARK: - Private: stale PID persistence

    private func persistPidRecords() {
        let records = Array(pidRecords.values)
        guard !records.isEmpty else {
            AppStorageEnvironment.shared.defaults.removeObject(forKey: Self.stalePidsDefaultsKey)
            return
        }
        do {
            let data = try JSONEncoder().encode(records)
            AppStorageEnvironment.shared.defaults.set(data, forKey: Self.stalePidsDefaultsKey)
        } catch {
            Self.logger.error("Failed to persist tunnel command PID records: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func isPortInUse(_ stderrTail: String) -> Bool {
        let lowered = stderrTail.lowercased()
        return lowered.contains("address already in use") || lowered.contains("bind: address already in use")
    }

    // MARK: - Private: App Nap

    private func updateAppNapState() {
        if !tunnels.isEmpty, appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Tunnel command process requires timely execution"
            )
        } else if tunnels.isEmpty, let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }
}

// MARK: - PID record

struct TunnelCommandPidRecord: Codable, Sendable, Equatable {
    let pid: Int32
    let binaryPath: String
    let executableName: String

    var reaperTarget: StaleProcessReaper.Target {
        StaleProcessReaper.Target(pid: pid, binaryPath: binaryPath, executableName: executableName)
    }
}

// MARK: - Startup monitor

private actor TunnelCommandStartupMonitor {
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
