//
//  TunnelCommandManagerTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

/// Stands in for the forwarding process. `.ready` opens a real loopback listener on the port the
/// manager put in the arguments, which is what the readiness probe is looking for.
final class FakeTunnelCommandRunner: SupervisedProcessRunner, @unchecked Sendable {
    enum Behavior {
        case ready
        case exitsDuringStartup(String)
        case neverReady
    }

    let behavior: Behavior
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var startedBinaryPath: String?
    private(set) var startedArguments: [String] = []
    private(set) var startedEnvironment: [String: String] = [:]
    private var listenerFd: Int32?

    let stderrLines: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation

    private let lock = NSLock()
    private var requested = false
    private var terminationResult: SubprocessTermination?
    private var terminationContinuation: CheckedContinuation<SubprocessTermination, Never>?

    init(behavior: Behavior) {
        self.behavior = behavior
        var continuation: AsyncStream<String>.Continuation!
        stderrLines = AsyncStream<String> { continuation = $0 }
        stderrContinuation = continuation
    }

    var processIdentifier: Int32? { 4_243 }

    func start(binaryPath: String, arguments: [String], environment: [String: String]) throws {
        lock.lock()
        startCallCount += 1
        startedBinaryPath = binaryPath
        startedArguments = arguments
        startedEnvironment = environment
        lock.unlock()

        switch behavior {
        case .ready:
            if let port = Self.parsePort(arguments) {
                listenerFd = Self.openListener(port: port)
            }
        case .exitsDuringStartup(let message):
            stderrContinuation.yield(message)
            finish(exitCode: 1)
        case .neverReady:
            break
        }
    }

    func stop() {
        lock.lock()
        requested = true
        stopCallCount += 1
        lock.unlock()
        if let fd = listenerFd {
            close(fd)
            listenerFd = nil
        }
        finish(exitCode: 0)
    }

    var termination: SubprocessTermination {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let cached = terminationResult {
                    lock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                terminationContinuation = continuation
                lock.unlock()
            }
        }
    }

    private func finish(exitCode: Int32) {
        lock.lock()
        if terminationResult != nil {
            lock.unlock()
            return
        }
        let result = SubprocessTermination(exitCode: exitCode, wasRequested: requested)
        terminationResult = result
        let pending = terminationContinuation
        terminationContinuation = nil
        lock.unlock()
        stderrContinuation.finish()
        pending?.resume(returning: result)
    }

    private static func parsePort(_ arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: "--listen"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    private static func openListener(port: Int) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }
}

@Suite("Tunnel command manager", .serialized)
struct TunnelCommandManagerTests {
    private func customConfig(command: String = "/bin/echo --listen {port}") -> TunnelCommandConfiguration {
        TunnelCommandConfiguration(method: .custom, command: command)
    }

    @Test("createTunnel returns the port the command was told to listen on")
    func readinessSucceeds() async throws {
        let fake = FakeTunnelCommandRunner(behavior: .ready)
        let manager = TunnelCommandManager(runnerFactory: { fake })
        let id = UUID()

        let port = try await manager.createTunnel(
            connectionId: id, config: customConfig(), remoteHost: "db.internal", remotePort: 5_432
        )

        #expect(port > 0)
        #expect(fake.startedBinaryPath == "/bin/echo")
        #expect(fake.startedArguments == ["--listen", String(port)])
        #expect(await manager.hasTunnel(connectionId: id))
        #expect(await manager.getLocalPort(connectionId: id) == port)

        try await manager.closeTunnel(connectionId: id)
        #expect(fake.stopCallCount >= 1)
        #expect(!(await manager.hasTunnel(connectionId: id)))
    }

    @Test("the command is launched with the tool paths on PATH")
    func launchesWithAugmentedPath() async throws {
        let fake = FakeTunnelCommandRunner(behavior: .ready)
        let manager = TunnelCommandManager(runnerFactory: { fake })
        _ = try await manager.createTunnel(
            connectionId: UUID(), config: customConfig(), remoteHost: "h", remotePort: 1
        )
        let path = fake.startedEnvironment["PATH"] ?? ""
        for toolPath in CLIToolEnvironment.toolPaths {
            #expect(path.contains(toolPath))
        }
        await manager.closeAllTunnels()
    }

    @Test("a command that exits during startup fails with its stderr")
    func startupFailureCarriesStderr() async {
        let fake = FakeTunnelCommandRunner(behavior: .exitsDuringStartup("error: pods \"pg\" not found"))
        let manager = TunnelCommandManager(runnerFactory: { fake })

        await #expect(throws: TunnelCommandError.self) {
            _ = try await manager.createTunnel(
                connectionId: UUID(), config: self.customConfig(), remoteHost: "h", remotePort: 1
            )
        }
    }

    @Test("a missing executable path is reported before anything starts")
    func missingExecutablePath() async {
        let fake = FakeTunnelCommandRunner(behavior: .ready)
        let manager = TunnelCommandManager(runnerFactory: { fake })

        await #expect(throws: TunnelCommandError.executableNotFound("/nonexistent/forward")) {
            _ = try await manager.createTunnel(
                connectionId: UUID(),
                config: self.customConfig(command: "/nonexistent/forward --listen {port}"),
                remoteHost: "h",
                remotePort: 1
            )
        }
        #expect(fake.startCallCount == 0)
    }

    @Test("a bare tool name that is not on PATH is reported by name")
    func missingToolOnPath() async {
        let fake = FakeTunnelCommandRunner(behavior: .ready)
        let manager = TunnelCommandManager(runnerFactory: { fake }, executableLookup: { _ in nil })

        await #expect(throws: TunnelCommandError.executableNotFound("kubectl")) {
            _ = try await manager.createTunnel(
                connectionId: UUID(),
                config: TunnelCommandConfiguration(method: .kubectl, kubernetesResource: "service/pg"),
                remoteHost: "h",
                remotePort: 5_432
            )
        }
        #expect(fake.startCallCount == 0)
    }

    @Test("a command missing the local port placeholder never starts")
    func missingPlaceholderNeverStarts() async {
        let fake = FakeTunnelCommandRunner(behavior: .ready)
        let manager = TunnelCommandManager(runnerFactory: { fake })

        await #expect(throws: TunnelCommandError.missingLocalPortPlaceholder) {
            _ = try await manager.createTunnel(
                connectionId: UUID(),
                config: self.customConfig(command: "/bin/echo --listen 5432"),
                remoteHost: "h",
                remotePort: 1
            )
        }
        #expect(fake.startCallCount == 0)
    }

    /// A cancelled connect has to take the process with it. The tunnel is not registered yet at
    /// that point, so nothing else would ever close it and it would hold its port until the next
    /// launch swept it.
    @Test("cancelling the connect stops the command it started")
    func cancellationStopsTheCommand() async throws {
        let fake = FakeTunnelCommandRunner(behavior: .neverReady)
        let manager = TunnelCommandManager(runnerFactory: { fake })

        let task = Task {
            try await manager.createTunnel(
                connectionId: UUID(), config: self.customConfig(), remoteHost: "h", remotePort: 1
            )
        }
        while fake.startCallCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        _ = try? await task.value

        #expect(fake.stopCallCount >= 1)
    }

    @Test("terminateAllProcessesSync stops the running command")
    func terminateAllStops() async throws {
        let fake = FakeTunnelCommandRunner(behavior: .ready)
        let manager = TunnelCommandManager(runnerFactory: { fake })
        _ = try await manager.createTunnel(
            connectionId: UUID(), config: customConfig(), remoteHost: "h", remotePort: 1
        )

        manager.terminateAllProcessesSync()
        #expect(fake.stopCallCount >= 1)

        await manager.closeAllTunnels()
        #expect(AppStorageEnvironment.shared.defaults.data(forKey: "tunnelCommandStalePids") == nil)
    }

    @Test("sweepStalePidsIfNeeded clears records for processes that are gone")
    func sweepClearsRecords() async {
        let records = [TunnelCommandPidRecord(pid: -1, binaryPath: "/nonexistent", executableName: "kubectl")]
        AppStorageEnvironment.shared.defaults.set(
            try? JSONEncoder().encode(records), forKey: "tunnelCommandStalePids"
        )

        let manager = TunnelCommandManager(runnerFactory: { FakeTunnelCommandRunner(behavior: .ready) })
        await manager.sweepStalePidsIfNeeded()

        #expect(AppStorageEnvironment.shared.defaults.data(forKey: "tunnelCommandStalePids") == nil)
    }
}
