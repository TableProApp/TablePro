//
//  CloudflareTunnelManagerTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

/// Fake cloudflared process. Depending on `behavior` it either opens a real
/// loopback listener (so the manager's readiness probe succeeds), prints a
/// browser sign-in line, or exits during startup.
final class FakeCloudflaredRunner: CloudflaredRunner, @unchecked Sendable {
    enum Behavior {
        case ready
        case browserAuth
        case startupFailure
    }

    let behavior: Behavior
    private(set) var stopCallCount = 0
    private var listenerFd: Int32?

    let stderrLines: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation

    private let lock = NSLock()
    private var requested = false
    private var terminationResult: CloudflaredTermination?
    private var terminationContinuation: CheckedContinuation<CloudflaredTermination, Never>?

    init(behavior: Behavior) {
        self.behavior = behavior
        var continuation: AsyncStream<String>.Continuation!
        stderrLines = AsyncStream<String> { continuation = $0 }
        stderrContinuation = continuation
    }

    var processIdentifier: Int32? { 4_242 }

    func start(binaryPath: String, arguments: [String], environment: [String: String]) throws {
        switch behavior {
        case .ready:
            if let port = Self.parsePort(arguments) {
                listenerFd = Self.openListener(port: port)
            }
        case .browserAuth:
            stderrContinuation.yield(
                "INF A browser window should have opened at the following URL: https://team.cloudflareaccess.com/cdn-cgi/access/cli?redirect_url=tcp"
            )
        case .startupFailure:
            stderrContinuation.yield("ERR failed to dial origin: connection refused")
            finish(exitCode: 1)
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

    var termination: CloudflaredTermination {
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
        let result = CloudflaredTermination(exitCode: exitCode, wasRequested: requested)
        terminationResult = result
        let pending = terminationContinuation
        terminationContinuation = nil
        lock.unlock()
        stderrContinuation.finish()
        pending?.resume(returning: result)
    }

    private static func parsePort(_ arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: "--url"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1].split(separator: ":").last.flatMap { Int($0) }
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

@Suite("Cloudflare tunnel manager", .serialized)
struct CloudflareTunnelManagerTests {
    private func config(hostname: String = "db.example.com", localPort: Int? = nil) -> CloudflareConfiguration {
        CloudflareConfiguration(accessHostname: hostname, localPort: localPort, binaryPath: "/bin/echo")
    }

    @Test("createTunnel returns the allocated port once cloudflared is listening")
    func readinessSucceeds() async throws {
        let fake = FakeCloudflaredRunner(behavior: .ready)
        let manager = CloudflareTunnelManager(runnerFactory: { fake })
        let id = UUID()

        let port = try await manager.createTunnel(connectionId: id, config: config())

        #expect(port > 0)
        #expect(await manager.hasTunnel(connectionId: id))
        #expect(await manager.getLocalPort(connectionId: id) == port)

        try await manager.closeTunnel(connectionId: id)
        #expect(fake.stopCallCount >= 1)
        #expect(!(await manager.hasTunnel(connectionId: id)))
    }

    @Test("createTunnel surfaces a browser sign-in prompt")
    func browserAuthDetected() async {
        let fake = FakeCloudflaredRunner(behavior: .browserAuth)
        let manager = CloudflareTunnelManager(runnerFactory: { fake })

        await #expect(throws: CloudflareTunnelError.self) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: self.config())
        }
    }

    @Test("createTunnel fails when cloudflared exits during startup")
    func startupFailure() async {
        let fake = FakeCloudflaredRunner(behavior: .startupFailure)
        let manager = CloudflareTunnelManager(runnerFactory: { fake })

        await #expect(throws: CloudflareTunnelError.self) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: self.config(localPort: 59_998))
        }
    }

    @Test("missing binary throws binaryNotFound")
    func missingBinary() async {
        let manager = CloudflareTunnelManager(runnerFactory: { FakeCloudflaredRunner(behavior: .ready) })
        let badConfig = CloudflareConfiguration(accessHostname: "db.example.com", binaryPath: "/nonexistent/cloudflared")

        await #expect(throws: CloudflareTunnelError.binaryNotFound) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: badConfig)
        }
    }

    @Test("terminateAllProcessesSync stops the running tunnel")
    func terminateAllStops() async throws {
        let fake = FakeCloudflaredRunner(behavior: .ready)
        let manager = CloudflareTunnelManager(runnerFactory: { fake })
        _ = try await manager.createTunnel(connectionId: UUID(), config: config())

        manager.terminateAllProcessesSync()
        #expect(fake.stopCallCount >= 1)

        await manager.closeAllTunnels()
        #expect(UserDefaults.standard.data(forKey: "cloudflaredStalePids") == nil)
    }

    @Test("sweepStalePidsIfNeeded clears the persisted records")
    func sweepClearsRecords() async {
        let records = [CloudflaredPidRecord(pid: -1, binaryPath: "/nonexistent")]
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: "cloudflaredStalePids")

        let manager = CloudflareTunnelManager(runnerFactory: { FakeCloudflaredRunner(behavior: .ready) })
        await manager.sweepStalePidsIfNeeded()

        #expect(UserDefaults.standard.data(forKey: "cloudflaredStalePids") == nil)
    }
}
