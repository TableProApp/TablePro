//
//  TunnelCreationRaceTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro
import TableProProcess
import TableProTestSupport

// A forwarding process that listens only once the test releases it, so one creation can be held mid-readiness.
final class HeldReadinessRunner: SupervisedProcessRunner, @unchecked Sendable {
    private let portInArguments: @Sendable ([String]) -> Int?
    private let lock = NSLock()
    private var isHeld: Bool
    private var startedPort: Int?
    private var listenerFd: Int32?
    private var starts = 0
    private var stops = 0
    private var arguments: [String] = []
    private var requested = false
    private var terminationResult: SubprocessTermination?
    private var terminationContinuation: CheckedContinuation<SubprocessTermination, Never>?

    let stderrLines: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation

    init(held: Bool, portInArguments: @escaping @Sendable ([String]) -> Int?) {
        isHeld = held
        self.portInArguments = portInArguments
        var continuation: AsyncStream<String>.Continuation!
        stderrLines = AsyncStream<String> { continuation = $0 }
        stderrContinuation = continuation
    }

    var processIdentifier: Int32? { nil }

    var hasStarted: Bool { lock.withLock { starts > 0 } }

    var stopCount: Int { lock.withLock { stops } }

    func argument(after flag: String) -> String? {
        lock.withLock {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
    }

    func start(_ command: ProcessCommand) throws {
        let port = portInArguments(command.arguments)
        lock.withLock {
            starts += 1
            startedPort = port
            arguments = command.arguments
            if !isHeld, let port { listenerFd = FakeCloudSQLProxyRunner.openListener(port: port) }
        }
    }

    func release() {
        lock.withLock {
            isHeld = false
            guard listenerFd == nil, let port = startedPort else { return }
            listenerFd = FakeCloudSQLProxyRunner.openListener(port: port)
        }
    }

    func stop() {
        lock.lock()
        requested = true
        stops += 1
        if let fd = listenerFd {
            close(fd)
            listenerFd = nil
        }
        lock.unlock()
        finish()
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

    private func finish() {
        lock.lock()
        guard terminationResult == nil else {
            lock.unlock()
            return
        }
        let result = SubprocessTermination(exitCode: 0, wasRequested: requested)
        terminationResult = result
        let pending = terminationContinuation
        terminationContinuation = nil
        lock.unlock()
        stderrContinuation.finish()
        pending?.resume(returning: result)
    }

    static func port(after flag: String) -> @Sendable ([String]) -> Int? {
        { arguments in
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            return Int(value.split(separator: ":").last.map(String.init) ?? value)
        }
    }
}

private final class RunnerQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var runners: [HeldReadinessRunner]

    init(_ runners: [HeldReadinessRunner]) {
        self.runners = runners
    }

    func next() -> HeldReadinessRunner {
        lock.withLock { runners.removeFirst() }
    }
}

private func expectSuperseded(_ result: Result<Int, any Error>) {
    guard case .failure(let error) = result else {
        Issue.record("The older creation adopted its tunnel over the newer one")
        return
    }
    #expect(error is CancellationError)
}

// Two creations for one connection: the older one is held until the newer one has its tunnel, then let go.
struct TunnelCreationRaceTests {
    @Test("The newest creation is the only one that may adopt")
    func generationsKeepTheNewest() {
        var generations = TunnelCreationGenerations()
        let id = UUID()
        let older = generations.begin(id)
        let newer = generations.begin(id)

        let elsewhere = generations.begin(UUID())

        #expect(!generations.isNewest(older, for: id))
        #expect(generations.isNewest(newer, for: id))
        #expect(!generations.isNewest(elsewhere, for: id))

        generations.finish(older, for: id)
        #expect(generations.isNewest(newer, for: id))
        generations.finish(newer, for: id)
        #expect(!generations.isNewest(older, for: id))
        #expect(!generations.isNewest(newer, for: id))
    }

    @Test("A tunnel command creation that lost the race stops its process and keeps the newer tunnel")
    func tunnelCommandRace() async throws {
        let older = HeldReadinessRunner(held: true, portInArguments: HeldReadinessRunner.port(after: "--listen"))
        let newer = HeldReadinessRunner(held: false, portInArguments: HeldReadinessRunner.port(after: "--listen"))
        let runners = RunnerQueue([older, newer])
        let manager = TunnelCommandManager(runnerFactory: { runners.next() })
        let config = TunnelCommandConfiguration(method: .custom, command: "/bin/echo --listen {port}")
        let id = UUID()

        let olderCreation = Task {
            try await manager.createTunnel(connectionId: id, config: config, remoteHost: "db.internal", remotePort: 5_432)
        }
        try await waitUntil { older.hasStarted }
        let newerPort = try await manager.createTunnel(
            connectionId: id, config: config, remoteHost: "db.internal", remotePort: 5_432
        )
        older.release()

        expectSuperseded(await olderCreation.result)
        #expect(await manager.getLocalPort(connectionId: id) == newerPort)
        #expect(older.stopCount == 1)
        #expect(newer.stopCount == 0)
        await manager.closeAllTunnels()
    }

    @Test("A Cloudflare creation that lost the race stops its process and keeps the newer tunnel")
    func cloudflareRace() async throws {
        let older = HeldReadinessRunner(held: true, portInArguments: HeldReadinessRunner.port(after: "--url"))
        let newer = HeldReadinessRunner(held: false, portInArguments: HeldReadinessRunner.port(after: "--url"))
        let runners = RunnerQueue([older, newer])
        let manager = CloudflareTunnelManager(runnerFactory: { runners.next() })
        let config = CloudflareConfiguration(accessHostname: "db.example.com", binaryPath: "/bin/echo")
        let id = UUID()

        let olderCreation = Task { try await manager.createTunnel(connectionId: id, config: config) }
        try await waitUntil { older.hasStarted }
        let newerPort = try await manager.createTunnel(connectionId: id, config: config)
        older.release()

        expectSuperseded(await olderCreation.result)
        #expect(await manager.getLocalPort(connectionId: id) == newerPort)
        #expect(older.stopCount == 1)
        #expect(newer.stopCount == 0)
        await manager.closeAllTunnels()
    }

    @Test("A Cloud SQL creation that lost the race stops its proxy and leaves the newer one its key file")
    func cloudSQLRace() async throws {
        let older = HeldReadinessRunner(held: true, portInArguments: HeldReadinessRunner.port(after: "--port"))
        let newer = HeldReadinessRunner(held: false, portInArguments: HeldReadinessRunner.port(after: "--port"))
        let runners = RunnerQueue([older, newer])
        let manager = CloudSQLProxyManager(runnerFactory: { runners.next() }, ownsListener: { _, _ in true })
        let config = CloudSQLProxyConfiguration(
            instanceConnectionName: "proj:region:inst",
            authMode: .serviceAccountKey,
            binaryPath: "/bin/echo"
        )
        let key = "{\"type\":\"service_account\"}"
        let id = UUID()

        let olderCreation = Task {
            try await manager.createTunnel(connectionId: id, config: config, serviceAccountKeyJSON: key)
        }
        try await waitUntil { older.hasStarted }
        let newerPort = try await manager.createTunnel(connectionId: id, config: config, serviceAccountKeyJSON: key)
        older.release()

        expectSuperseded(await olderCreation.result)
        #expect(await manager.getLocalPort(connectionId: id) == newerPort)
        #expect(older.stopCount == 1)
        #expect(newer.stopCount == 0)
        let olderKey = try #require(older.argument(after: "--credentials-file"))
        let newerKey = try #require(newer.argument(after: "--credentials-file"))
        #expect(olderKey != newerKey)
        #expect(!FileManager.default.fileExists(atPath: olderKey))
        #expect(FileManager.default.fileExists(atPath: newerKey))
        await manager.closeAllTunnels()
        #expect(!FileManager.default.fileExists(atPath: newerKey))
    }

    @Test("A SOCKS creation that lost the race closes its listener and keeps the newer tunnel")
    func socksRace() async throws {
        let gate = AsyncGate()
        let held = FakeSOCKS5Server(behavior: .echo, connectReplyGate: gate)
        let prompt = FakeSOCKS5Server(behavior: .echo)
        try await held.start()
        try await prompt.start()
        defer {
            held.stop()
            prompt.stop()
        }
        let manager = SOCKSProxyManager(connectTimeout: 10)
        let id = UUID()

        let olderCreation = Task {
            try await manager.createTunnel(
                connectionId: id,
                config: SOCKSProxyConfiguration(host: "127.0.0.1", port: held.port),
                password: nil,
                targetHost: "db.internal.example",
                targetPort: 5_432
            )
        }
        try await waitUntil { held.capturedConnectRequest != nil }
        let newerPort = try await manager.createTunnel(
            connectionId: id,
            config: SOCKSProxyConfiguration(host: "127.0.0.1", port: prompt.port),
            password: nil,
            targetHost: "db.internal.example",
            targetPort: 5_432
        )
        await gate.open()

        expectSuperseded(await olderCreation.result)
        #expect(await manager.getLocalPort(connectionId: id) == newerPort)
        await manager.closeAllTunnels()
    }
}

// A close while a creation still waits on readiness: nothing may be adopted after the close returned.
struct TunnelCloseDuringCreationTests {
    @Test("Closing a tunnel command that is still dialing stops its process and adopts nothing")
    func tunnelCommandClose() async throws {
        let held = HeldReadinessRunner(held: true, portInArguments: HeldReadinessRunner.port(after: "--listen"))
        let manager = TunnelCommandManager(runnerFactory: { held })
        let config = TunnelCommandConfiguration(method: .custom, command: "/bin/echo --listen {port}")
        let id = UUID()

        let creation = Task {
            try await manager.createTunnel(connectionId: id, config: config, remoteHost: "db.internal", remotePort: 5_432)
        }
        try await waitUntil { held.hasStarted }
        try await manager.closeTunnel(connectionId: id)
        held.release()

        expectSuperseded(await creation.result)
        #expect(await !manager.hasTunnel(connectionId: id))
        #expect(held.stopCount == 1)
    }

    @Test("Closing every Cloudflare tunnel also ends one that is still dialing")
    func cloudflareCloseAll() async throws {
        let held = HeldReadinessRunner(held: true, portInArguments: HeldReadinessRunner.port(after: "--url"))
        let manager = CloudflareTunnelManager(runnerFactory: { held })
        let config = CloudflareConfiguration(accessHostname: "db.example.com", binaryPath: "/bin/echo")
        let id = UUID()

        let creation = Task { try await manager.createTunnel(connectionId: id, config: config) }
        try await waitUntil { held.hasStarted }
        await manager.closeAllTunnels()
        held.release()

        expectSuperseded(await creation.result)
        #expect(await !manager.hasTunnel(connectionId: id))
        #expect(held.stopCount == 1)
    }

    @Test("Closing a Cloud SQL proxy that is still dialing stops it and removes its key file")
    func cloudSQLClose() async throws {
        let held = HeldReadinessRunner(held: true, portInArguments: HeldReadinessRunner.port(after: "--port"))
        let manager = CloudSQLProxyManager(runnerFactory: { held }, ownsListener: { _, _ in true })
        let config = CloudSQLProxyConfiguration(
            instanceConnectionName: "proj:region:inst",
            authMode: .serviceAccountKey,
            binaryPath: "/bin/echo"
        )
        let id = UUID()

        let creation = Task {
            try await manager.createTunnel(connectionId: id, config: config, serviceAccountKeyJSON: "{}")
        }
        try await waitUntil { held.hasStarted }
        try await manager.closeTunnel(connectionId: id)
        held.release()

        expectSuperseded(await creation.result)
        #expect(await !manager.hasTunnel(connectionId: id))
        #expect(held.stopCount == 1)
        let key = try #require(held.argument(after: "--credentials-file"))
        #expect(!FileManager.default.fileExists(atPath: key))
    }

    @Test("A newer Cloud SQL attempt that fails before writing its key leaves no key file behind")
    func cloudSQLNewerFailureLeavesNoKey() async throws {
        let held = HeldReadinessRunner(held: true, portInArguments: HeldReadinessRunner.port(after: "--port"))
        let manager = CloudSQLProxyManager(runnerFactory: { held }, ownsListener: { _, _ in true })
        let config = CloudSQLProxyConfiguration(
            instanceConnectionName: "proj:region:inst",
            authMode: .serviceAccountKey,
            binaryPath: "/bin/echo"
        )
        let missingBinary = CloudSQLProxyConfiguration(
            instanceConnectionName: "proj:region:inst",
            authMode: .serviceAccountKey,
            binaryPath: "/nonexistent/cloud-sql-proxy"
        )
        let id = UUID()

        let older = Task {
            try await manager.createTunnel(connectionId: id, config: config, serviceAccountKeyJSON: "{}")
        }
        try await waitUntil { held.hasStarted }
        await #expect(throws: (any Error).self) {
            _ = try await manager.createTunnel(connectionId: id, config: missingBinary, serviceAccountKeyJSON: "{}")
        }
        held.release()

        expectSuperseded(await older.result)
        let key = try #require(held.argument(after: "--credentials-file"))
        #expect(!FileManager.default.fileExists(atPath: key))
        #expect(await !manager.hasTunnel(connectionId: id))
    }

    @Test("Closing a SOCKS tunnel that is still probing closes its listener and adopts nothing")
    func socksClose() async throws {
        let gate = AsyncGate()
        let server = FakeSOCKS5Server(behavior: .echo, connectReplyGate: gate)
        try await server.start()
        defer { server.stop() }
        let manager = SOCKSProxyManager(connectTimeout: 10)
        let id = UUID()

        let creation = Task {
            try await manager.createTunnel(
                connectionId: id,
                config: SOCKSProxyConfiguration(host: "127.0.0.1", port: server.port),
                password: nil,
                targetHost: "db.internal.example",
                targetPort: 5_432
            )
        }
        try await waitUntil { server.capturedConnectRequest != nil }
        try await manager.closeTunnel(connectionId: id)
        await gate.open()

        expectSuperseded(await creation.result)
        #expect(await !manager.hasTunnel(connectionId: id))
    }
}
