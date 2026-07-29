//
//  CloudSQLProxyManagerTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

final class FakeCloudSQLProxyRunner: SupervisedProcessRunner, @unchecked Sendable {
    enum Behavior {
        case ready
        case startupFailure
    }

    let behavior: Behavior
    private(set) var stopCallCount = 0
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

    var processIdentifier: Int32? { 4_242 }

    func start(binaryPath: String, arguments: [String], environment: [String: String]) throws {
        switch behavior {
        case .ready:
            if let port = Self.parsePort(arguments) {
                listenerFd = Self.openListener(port: port)
            }
        case .startupFailure:
            stderrContinuation.yield("failed to connect to instance: permission denied")
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
        guard let index = arguments.firstIndex(of: "--port"), index + 1 < arguments.count else { return nil }
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

@Suite("Cloud SQL Auth Proxy manager", .serialized)
struct CloudSQLProxyManagerTests {
    private func config(instance: String = "proj:region:inst", localPort: Int? = nil) -> CloudSQLProxyConfiguration {
        CloudSQLProxyConfiguration(instanceConnectionName: instance, localPort: localPort, binaryPath: "/bin/echo")
    }

    @Test("createTunnel returns the allocated port once the proxy is listening")
    func readinessSucceeds() async throws {
        let fake = FakeCloudSQLProxyRunner(behavior: .ready)
        let manager = CloudSQLProxyManager(runnerFactory: { fake })
        let id = UUID()

        let port = try await manager.createTunnel(connectionId: id, config: config())

        #expect(port > 0)
        #expect(await manager.hasTunnel(connectionId: id))
        #expect(await manager.getLocalPort(connectionId: id) == port)

        try await manager.closeTunnel(connectionId: id)
        #expect(fake.stopCallCount >= 1)
        #expect(!(await manager.hasTunnel(connectionId: id)))
    }

    @Test("createTunnel fails when the proxy exits during startup")
    func startupFailure() async {
        let fake = FakeCloudSQLProxyRunner(behavior: .startupFailure)
        let manager = CloudSQLProxyManager(runnerFactory: { fake })

        await #expect(throws: CloudSQLProxyError.self) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: self.config(localPort: 59_997))
        }
    }

    @Test("an invalid instance connection name is rejected before launching")
    func invalidInstance() async {
        let manager = CloudSQLProxyManager(runnerFactory: { FakeCloudSQLProxyRunner(behavior: .ready) })

        await #expect(throws: CloudSQLProxyError.invalidInstanceConnectionName) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: self.config(instance: "not-valid"))
        }
    }

    @Test("missing binary throws binaryNotFound")
    func missingBinary() async {
        let manager = CloudSQLProxyManager(runnerFactory: { FakeCloudSQLProxyRunner(behavior: .ready) })
        let badConfig = CloudSQLProxyConfiguration(instanceConnectionName: "p:r:i", binaryPath: "/nonexistent/cloud-sql-proxy")

        await #expect(throws: CloudSQLProxyError.binaryNotFound) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: badConfig)
        }
    }

    @Test("service account key is written 0600 and removed on close")
    func credentialsFileLifecycle() async throws {
        let fake = FakeCloudSQLProxyRunner(behavior: .ready)
        let manager = CloudSQLProxyManager(runnerFactory: { fake })
        let id = UUID()
        let keyConfig = CloudSQLProxyConfiguration(
            instanceConnectionName: "proj:region:inst",
            authMode: .serviceAccountKey,
            binaryPath: "/bin/echo"
        )

        _ = try await manager.createTunnel(
            connectionId: id,
            config: keyConfig,
            serviceAccountKeyJSON: "{\"type\":\"service_account\"}"
        )

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.TablePro.cloudsqlproxy.\(id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: path.path))
        let perms = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        try await manager.closeTunnel(connectionId: id)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("terminateAllProcessesSync stops the running proxy")
    func terminateAllStops() async throws {
        let fake = FakeCloudSQLProxyRunner(behavior: .ready)
        let manager = CloudSQLProxyManager(runnerFactory: { fake })
        _ = try await manager.createTunnel(connectionId: UUID(), config: config())

        manager.terminateAllProcessesSync()
        #expect(fake.stopCallCount >= 1)

        await manager.closeAllTunnels()
        #expect(UserDefaults.standard.data(forKey: "cloudSQLProxyStalePids") == nil)
    }

    @Test("sweepStalePidsIfNeeded clears the persisted records")
    func sweepClearsRecords() async {
        let records = [CloudSQLProxyPidRecord(pid: -1, binaryPath: "/nonexistent")]
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: "cloudSQLProxyStalePids")

        let manager = CloudSQLProxyManager(runnerFactory: { FakeCloudSQLProxyRunner(behavior: .ready) })
        await manager.sweepStalePidsIfNeeded()

        #expect(UserDefaults.standard.data(forKey: "cloudSQLProxyStalePids") == nil)
    }
}
