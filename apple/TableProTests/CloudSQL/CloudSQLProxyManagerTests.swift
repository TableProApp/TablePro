import Darwin
import Foundation
import Testing

@testable import TablePro
import TableProProcess
import TableProTestSupport

final class FakeCloudSQLProxyRunner: SupervisedProcessRunner, @unchecked Sendable {
    enum Behavior {
        case ready
        case startupFailure
        case neverReady
        // Another program takes the port after the manager's check and before the proxy binds it.
        case squatted
    }

    let behavior: Behavior
    private var startCalls = 0
    private var stopCalls = 0
    private var startedArgumentList: [String] = []
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

    var startCallCount: Int {
        lock.withLock { startCalls }
    }

    var stopCallCount: Int {
        lock.withLock { stopCalls }
    }

    var startedArguments: [String] {
        lock.withLock { startedArgumentList }
    }

    func start(_ command: ProcessCommand) throws {
        _ = try ProcessLauncher.process(for: command)
        lock.withLock {
            startCalls += 1
            startedArgumentList = command.arguments
        }

        switch behavior {
        case .ready, .squatted:
            if let port = Self.parsePort(command.arguments) {
                listenerFd = Self.openListener(port: port)
            }
        case .startupFailure:
            stderrContinuation.yield("failed to connect to instance: permission denied")
            finish(exitCode: 1)
        case .neverReady:
            break
        }
    }

    func stop() {
        lock.lock()
        requested = true
        stopCalls += 1
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

    static func openListener(port: Int) -> Int32? {
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

// The fake runner's listener stands in for the proxy's, so these managers take it as the proxy's own.
private extension CloudSQLProxyManager {
    init(
        testRunner: @escaping () -> any SupervisedProcessRunner,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.init(runnerFactory: testRunner, ownsListener: { _, _ in true }, temporaryDirectory: temporaryDirectory)
    }
}

@Suite("Cloud SQL Auth Proxy manager", .serialized)
struct CloudSQLProxyManagerTests {
    private static let credentialsFolderName = "com.TablePro.cloudsqlproxy"
    private static let credentialsFolderAdoptedKey = "com.TablePro.cloudSQLCredentialsFolderAdopted"

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudsqlproxy-tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func plantKeyFile(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("com.TablePro.cloudsqlproxy.\(UUID().uuidString)-\(UUID().uuidString).json")
        try Data("{\"type\":\"service_account\"}".utf8).write(to: file)
        return file
    }

    private func config(instance: String = "proj:region:inst", localPort: Int? = nil) -> CloudSQLProxyConfiguration {
        CloudSQLProxyConfiguration(instanceConnectionName: instance, localPort: localPort, binaryPath: "/bin/echo")
    }

    // The launch path once checked only that the file existed, so the pinned checksum went unread before exec.
    @Test("A tampered managed binary is refused rather than launched")
    func tamperedManagedBinaryIsRefused() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudsqlproxy-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = dir.appendingPathComponent("cloud-sql-proxy")
        try Data("swapped in later".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try CloudSQLProxyBinaryManager.pinnedVersion
            .write(to: dir.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)

        let started = LaunchFlag()
        let binaryManager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: ["arm64": "deadbeef", "amd64": "deadbeef"],
            download: TestProxyDownload.serving(Data("still wrong".utf8), into: dir)
        )
        let manager = CloudSQLProxyManager(
            runnerFactory: {
                started.set()
                return FakeCloudSQLProxyRunner(behavior: .ready)
            },
            managedBinary: { try await binaryManager.ensureBinary() },
            systemBinaryLookup: { _ in nil },
            ownsListener: { _, _ in true }
        )

        await #expect(throws: CloudSQLProxyError.checksumMismatch) {
            _ = try await manager.createTunnel(
                connectionId: UUID(),
                config: CloudSQLProxyConfiguration(
                    instanceConnectionName: "proj:region:inst",
                    localPort: nil,
                    binaryPath: ""
                )
            )
        }
        #expect(!started.value, "the proxy was launched despite failing its checksum")
    }

    @Test("A managed binary matching its pin is launched")
    func verifiedManagedBinaryIsLaunched() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudsqlproxy-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data("pinned build".utf8)
        let binaryManager = CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(bytes),
            download: TestProxyDownload.serving(bytes, into: dir)
        )

        let manager = CloudSQLProxyManager(
            runnerFactory: { FakeCloudSQLProxyRunner(behavior: .ready) },
            managedBinary: { try await binaryManager.ensureBinary() },
            systemBinaryLookup: { _ in nil },
            ownsListener: { _, _ in true }
        )

        let port = try await manager.createTunnel(
            connectionId: UUID(),
            config: CloudSQLProxyConfiguration(
                instanceConnectionName: "proj:region:inst",
                localPort: nil,
                binaryPath: ""
            )
        )

        #expect(port > 0)
    }

    @Test("createTunnel returns the allocated port once the proxy is listening")
    func readinessSucceeds() async throws {
        let fake = FakeCloudSQLProxyRunner(behavior: .ready)
        let manager = CloudSQLProxyManager(testRunner: { fake })
        let id = UUID()

        let port = try await manager.createTunnel(connectionId: id, config: config())

        #expect(port > 0)
        #expect(await manager.hasTunnel(connectionId: id))
        #expect(await manager.getLocalPort(connectionId: id) == port)

        try await manager.closeTunnel(connectionId: id)
        #expect(fake.stopCallCount >= 1)
        #expect(!(await manager.hasTunnel(connectionId: id)))
    }

    @Test("A configured port another program already listens on is refused before the proxy starts")
    func occupiedPortIsRefused() async throws {
        let port = try #require(LoopbackPort.allocateFree())
        let squatter = try #require(FakeCloudSQLProxyRunner.openListener(port: port))
        defer { close(squatter) }
        let fake = FakeCloudSQLProxyRunner(behavior: .ready)
        let manager = CloudSQLProxyManager(testRunner: { fake })

        await #expect(throws: CloudSQLProxyError.portInUse(port)) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: self.config(localPort: port))
        }
        #expect(fake.startCallCount == 0)
    }

    @Test("A listener the proxy process does not own is never taken for the proxy")
    func listenerTheProxyDoesNotOwnIsRefused() async throws {
        let fake = FakeCloudSQLProxyRunner(behavior: .squatted)
        let manager = CloudSQLProxyManager(runnerFactory: { fake })
        let deadline = ConnectionDeadline(
            configuredSeconds: 30,
            instant: ContinuousClock.now.advanced(by: .milliseconds(800))
        )

        await #expect(throws: (any Error).self) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: self.config(), deadline: deadline)
        }
        #expect(fake.stopCallCount >= 1)
    }

    @Test("createTunnel fails when the proxy exits during startup")
    func startupFailure() async {
        let fake = FakeCloudSQLProxyRunner(behavior: .startupFailure)
        let manager = CloudSQLProxyManager(testRunner: { fake })

        await #expect(throws: CloudSQLProxyError.self) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: self.config(localPort: 59_997))
        }
    }

    @Test("connect deadline stops the proxy before registration")
    func deadlineStopsUnreadyProcess() async throws {
        let fake = FakeCloudSQLProxyRunner(behavior: .neverReady)
        let manager = CloudSQLProxyManager(testRunner: { fake })
        let id = UUID()
        let creation = Task {
            let deadline = ConnectionDeadline(
                configuredSeconds: 30,
                instant: ContinuousClock.now.advanced(by: .milliseconds(500))
            )
            return try await manager.createTunnel(
                connectionId: id,
                config: self.config(),
                deadline: deadline
            )
        }
        defer {
            creation.cancel()
            fake.stop()
        }

        try await waitUntil { fake.startCallCount > 0 }
        let result = try #require(await BoundedCall.result(within: .seconds(2)) {
            await creation.result
        })
        guard case .failure(let error) = result else {
            Issue.record("Expected proxy readiness to reach the connection deadline")
            return
        }
        #expect((error as? ConnectionTimeoutError) == ConnectionTimeoutError(
            endpoint: .proxy("proj:region:inst"),
            configuredSeconds: 30
        ))
        #expect(fake.stopCallCount >= 1)
        #expect(!(await manager.hasTunnel(connectionId: id)))
    }

    @Test("The instance name follows --, so a name that reads as a flag stays the instance")
    func instanceFollowsEndOfOptions() async throws {
        let fake = FakeCloudSQLProxyRunner(behavior: .ready)
        let manager = CloudSQLProxyManager(testRunner: { fake })
        let id = UUID()

        _ = try await manager.createTunnel(connectionId: id, config: config(instance: "--credentials-file=/a:b:c"))

        #expect(Array(fake.startedArguments.suffix(2)) == ["--", "--credentials-file=/a:b:c"])
        try await manager.closeTunnel(connectionId: id)
    }

    @Test("an invalid instance connection name is rejected before launching")
    func invalidInstance() async {
        let manager = CloudSQLProxyManager(testRunner: { FakeCloudSQLProxyRunner(behavior: .ready) })

        await #expect(throws: CloudSQLProxyError.invalidInstanceConnectionName) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: self.config(instance: "not-valid"))
        }
    }

    @Test("missing binary throws binaryNotFound")
    func missingBinary() async {
        let manager = CloudSQLProxyManager(testRunner: { FakeCloudSQLProxyRunner(behavior: .ready) })
        let badConfig = CloudSQLProxyConfiguration(instanceConnectionName: "p:r:i", binaryPath: "/nonexistent/cloud-sql-proxy")

        await #expect(throws: CloudSQLProxyError.binaryNotFound) {
            _ = try await manager.createTunnel(connectionId: UUID(), config: badConfig)
        }
    }

    @Test("service account key is written 0600 in a 0700 folder of its own and removed on close")
    func credentialsFileLifecycle() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fake = FakeCloudSQLProxyRunner(behavior: .ready)
        let manager = CloudSQLProxyManager(testRunner: { fake }, temporaryDirectory: base)
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

        let arguments = fake.startedArguments
        let flag = try #require(arguments.firstIndex(of: "--credentials-file"))
        let path = URL(fileURLWithPath: arguments[flag + 1])
        let folder = base.appendingPathComponent(Self.credentialsFolderName, isDirectory: true)
        #expect(path.deletingLastPathComponent().path == folder.path)
        #expect(path.lastPathComponent.hasPrefix("com.TablePro.cloudsqlproxy.\(id.uuidString)-"))
        #expect(FileManager.default.fileExists(atPath: path.path))
        let perms = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let folderPerms = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(folderPerms == 0o700)

        try await manager.closeTunnel(connectionId: id)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("The sweep removes a key file left in its folder and, once adopted, leaves the temp folder unlisted")
    func sweepRemovesKeysInItsFolderOnly() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        AppStorageEnvironment.shared.defaults.set(true, forKey: Self.credentialsFolderAdoptedKey)
        AppStorageEnvironment.shared.defaults.removeObject(forKey: "cloudSQLProxyStalePids")
        let leftInFolder = try plantKeyFile(in: base.appendingPathComponent(Self.credentialsFolderName, isDirectory: true))
        let outsideFolder = try plantKeyFile(in: base)

        let manager = CloudSQLProxyManager(testRunner: { FakeCloudSQLProxyRunner(behavior: .ready) }, temporaryDirectory: base)
        await manager.sweepStalePidsIfNeeded()

        #expect(!FileManager.default.fileExists(atPath: leftInFolder.path))
        #expect(FileManager.default.fileExists(atPath: outsideFolder.path))
    }

    @Test("A key an older build left in the temp folder goes on the first sweep, and later sweeps do not list the temp folder")
    func olderBuildKeysGoOnTheFirstSweepOnly() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let defaults = AppStorageEnvironment.shared.defaults
        defaults.removeObject(forKey: Self.credentialsFolderAdoptedKey)
        defaults.removeObject(forKey: "cloudSQLProxyStalePids")
        let leftByOlderBuild = try plantKeyFile(in: base)
        let unrelated = base.appendingPathComponent("unrelated.json")
        try Data("{}".utf8).write(to: unrelated)

        await CloudSQLProxyManager(testRunner: { FakeCloudSQLProxyRunner(behavior: .ready) }, temporaryDirectory: base)
            .sweepStalePidsIfNeeded()

        #expect(!FileManager.default.fileExists(atPath: leftByOlderBuild.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(defaults.bool(forKey: Self.credentialsFolderAdoptedKey))

        let plantedAfterAdoption = try plantKeyFile(in: base)
        await CloudSQLProxyManager(testRunner: { FakeCloudSQLProxyRunner(behavior: .ready) }, temporaryDirectory: base)
            .sweepStalePidsIfNeeded()

        #expect(FileManager.default.fileExists(atPath: plantedAfterAdoption.path), "a later sweep listed the temp folder")
    }

    // An older build run since adoption leaves its record behind when it dies with a tunnel open.
    @Test("A run that left a proxy record sends the next sweep through the temp folder again")
    func staleRecordListsTheTempFolderAgain() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let defaults = AppStorageEnvironment.shared.defaults
        defaults.set(true, forKey: Self.credentialsFolderAdoptedKey)
        defaults.set(
            try JSONEncoder().encode([CloudSQLProxyPidRecord(pid: -1, binaryPath: "/nonexistent")]),
            forKey: "cloudSQLProxyStalePids"
        )
        let leftByOlderBuild = try plantKeyFile(in: base)

        await CloudSQLProxyManager(testRunner: { FakeCloudSQLProxyRunner(behavior: .ready) }, temporaryDirectory: base)
            .sweepStalePidsIfNeeded()

        #expect(!FileManager.default.fileExists(atPath: leftByOlderBuild.path))
    }

    @Test("A key the sweep could not remove keeps the one-time listing for the next launch")
    func failedRemovalKeepsTheListing() async throws {
        let base = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
            try? FileManager.default.removeItem(at: base)
        }
        let defaults = AppStorageEnvironment.shared.defaults
        defaults.removeObject(forKey: Self.credentialsFolderAdoptedKey)
        defaults.removeObject(forKey: "cloudSQLProxyStalePids")
        let stuck = try plantKeyFile(in: base)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: base.path)

        await CloudSQLProxyManager(testRunner: { FakeCloudSQLProxyRunner(behavior: .ready) }, temporaryDirectory: base)
            .sweepStalePidsIfNeeded()

        #expect(FileManager.default.fileExists(atPath: stuck.path))
        #expect(!defaults.bool(forKey: Self.credentialsFolderAdoptedKey))
        defaults.set(true, forKey: Self.credentialsFolderAdoptedKey)
    }

    @Test("Quit removes key files from the folder and does not list the temp folder")
    func quitRemovesKeysInTheFolderOnly() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let leftInFolder = try plantKeyFile(in: base.appendingPathComponent(Self.credentialsFolderName, isDirectory: true))
        let outsideFolder = try plantKeyFile(in: base)

        CloudSQLProxyManager(testRunner: { FakeCloudSQLProxyRunner(behavior: .ready) }, temporaryDirectory: base)
            .terminateAllProcessesSync()

        #expect(!FileManager.default.fileExists(atPath: leftInFolder.path))
        #expect(FileManager.default.fileExists(atPath: outsideFolder.path))
    }

    @Test("terminateAllProcessesSync stops the running proxy")
    func terminateAllStops() async throws {
        let fake = FakeCloudSQLProxyRunner(behavior: .ready)
        let manager = CloudSQLProxyManager(testRunner: { fake })
        _ = try await manager.createTunnel(connectionId: UUID(), config: config())

        manager.terminateAllProcessesSync()
        #expect(fake.stopCallCount >= 1)

        await manager.closeAllTunnels()
        #expect(AppStorageEnvironment.shared.defaults.data(forKey: "cloudSQLProxyStalePids") == nil)
    }

    @Test("sweepStalePidsIfNeeded clears the persisted records")
    func sweepClearsRecords() async {
        let records = [CloudSQLProxyPidRecord(pid: -1, binaryPath: "/nonexistent")]
        AppStorageEnvironment.shared.defaults.set(
            try? JSONEncoder().encode(records),
            forKey: "cloudSQLProxyStalePids"
        )

        let manager = CloudSQLProxyManager(testRunner: { FakeCloudSQLProxyRunner(behavior: .ready) })
        await manager.sweepStalePidsIfNeeded()

        #expect(AppStorageEnvironment.shared.defaults.data(forKey: "cloudSQLProxyStalePids") == nil)
    }
}

private final class LaunchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
