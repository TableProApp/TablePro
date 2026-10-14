import Foundation
@testable import TablePro
import XCTest

final class MCPHandshakeTrustTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-handshake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testLoadsAHandshakeWrittenForThisProcess() throws {
        try write(payload(), permissions: 0o600)
        let loaded = try MCPHandshakeTrust.load(at: url, now: Date())
        XCTAssertEqual(loaded.port, 23_508)
        XCTAssertEqual(loaded.token, "tp_test")
        XCTAssertEqual(loaded.version, MCPHandshakePayload.currentVersion)
    }

    func testRejectsAGroupReadableFile() throws {
        try write(payload(), permissions: 0o640)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            XCTAssertEqual(error as? MCPHandshakeTrustFailure, .worldReadable)
        }
    }

    func testRejectsAWorldReadableFile() throws {
        try write(payload(), permissions: 0o604)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            XCTAssertEqual(error as? MCPHandshakeTrustFailure, .worldReadable)
        }
    }

    func testRejectsAGroupOrWorldWritableFile() throws {
        for permissions in [0o620, 0o602] {
            try write(payload(), permissions: permissions)
            XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
                XCTAssertEqual(error as? MCPHandshakeTrustFailure, .worldReadable)
            }
        }
    }

    func testAcceptsAnOwnerOnlyFile() throws {
        try write(payload(), permissions: 0o600)
        XCTAssertNoThrow(try MCPHandshakeTrust.load(at: url, now: Date()))
    }

    func testRejectsAGroupWritableDirectory() throws {
        try write(payload(), permissions: 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            XCTAssertEqual(error as? MCPHandshakeTrustFailure, .unreadableDirectory)
        }
    }

    func testRejectsAWorldWritableDirectory() throws {
        try write(payload(), permissions: 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o707], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            XCTAssertEqual(error as? MCPHandshakeTrustFailure, .unreadableDirectory)
        }
    }

    func testRejectsAPathThatIsNotARegularFile() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            XCTAssertEqual(error as? MCPHandshakeTrustFailure, .notARegularFile)
        }
    }

    func testRejectsAnExpiredCredential() throws {
        try write(payload(expiresAt: Date().addingTimeInterval(-1)), permissions: 0o600)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            XCTAssertEqual(error as? MCPHandshakeTrustFailure, .expired)
        }
    }

    func testTreatsTheExpiryInstantItselfAsExpired() throws {
        let expiresAt = Date(timeIntervalSince1970: 1_700_000_000)
        try write(payload(expiresAt: expiresAt), permissions: 0o600)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: expiresAt)) { error in
            XCTAssertEqual(error as? MCPHandshakeTrustFailure, .expired)
        }
    }

    func testRejectsADeadHostProcess() throws {
        try write(payload(pid: 0x7FFF_FFFE), permissions: 0o600)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            XCTAssertEqual(
                error as? MCPHandshakeTrustFailure,
                .hostNotRunning(pid: 0x7FFF_FFFE)
            )
        }
    }

    func testRejectsAHandshakePointingAtALiveProcessThatIsNotThisApp() throws {
        let foreignPid = try startForeignProcess()
        try write(payload(pid: foreignPid), permissions: 0o600)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            guard let failure = error as? MCPHandshakeTrustFailure,
                  case .hostIsNotTablePro(let hostPath) = failure else {
                XCTFail("Expected the host check to reject a foreign executable, got \(error)")
                return
            }
            XCTAssertFalse(hostPath.isEmpty)
        }
    }

    func testRejectsAFileWrittenByAnOlderFormat() throws {
        let legacy = Data(#"""
        {"version":1,"port":1,"token":"t","pid":1,"instanceId":"i",\#
        "protocolVersion":"x","expiresAt":"2999-01-01T00:00:00Z"}
        """#.utf8)
        try create(legacy, permissions: 0o600)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            XCTAssertEqual(error as? MCPHandshakeTrustFailure, .unsupportedVersion(1))
        }
    }

    func testRejectsContentThatIsNotAHandshake() throws {
        try create(Data("not json at all".utf8), permissions: 0o600)
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            XCTAssertEqual(error as? MCPHandshakeTrustFailure, .malformed)
        }
    }

    func testRejectsAnEmptyTokenOrInstanceId() throws {
        for candidate in [payload(token: ""), payload(instanceId: "")] {
            try write(candidate, permissions: 0o600)
            XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
                XCTAssertEqual(error as? MCPHandshakeTrustFailure, .malformed)
            }
        }
    }

    func testRejectsAPortOutsideTheValidRange() throws {
        for port in [0, 65_536, -1] {
            try write(payload(port: port), permissions: 0o600)
            XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
                XCTAssertEqual(error as? MCPHandshakeTrustFailure, .malformed)
            }
        }
    }

    func testMissingFileReportsMissing() {
        XCTAssertThrowsError(try MCPHandshakeTrust.load(at: url, now: Date())) { error in
            XCTAssertEqual(error as? MCPHandshakeTrustFailure, .missing)
        }
    }

    func testPayloadRoundTripsThroughItsCoding() throws {
        let original = payload()
        let data = try MCPHandshakeCoding.encoder().encode(original)
        let decoded = try MCPHandshakeCoding.decoder().decode(MCPHandshakePayload.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.endpoint?.absoluteString, "http://127.0.0.1:23508/mcp")
    }

    func testTheEndpointIsAlwaysLoopback() throws {
        XCTAssertEqual(payload(port: 1).endpoint?.host, "127.0.0.1")
        XCTAssertEqual(payload(port: 65_535).endpoint?.scheme, "http")
    }

    func testTheSandboxVariableRedirectsTheSupportDirectory() {
        let sandbox = MCPHandshakeLocation.supportDirectory(
            environment: [MCPHandshakeLocation.sandboxEnvironmentVariable: "/tmp/tablepro-sandbox"]
        )
        XCTAssertEqual(sandbox.path, "/tmp/tablepro-sandbox/TablePro")

        let blank = MCPHandshakeLocation.supportDirectory(
            environment: [MCPHandshakeLocation.sandboxEnvironmentVariable: "   "]
        )
        XCTAssertTrue(blank.path.hasSuffix("/TablePro"))
        XCTAssertNotEqual(blank.path, "/TablePro")
        XCTAssertEqual(MCPHandshakeLocation.file(in: sandbox).lastPathComponent, "mcp-handshake.json")
    }

    private var url: URL {
        MCPHandshakeLocation.file(in: directory)
    }

    private func payload(
        port: Int = 23_508,
        token: String = "tp_test",
        instanceId: String = "instance",
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        expiresAt: Date = Date().addingTimeInterval(3_600)
    ) -> MCPHandshakePayload {
        MCPHandshakePayload(
            port: port,
            token: token,
            pid: pid,
            instanceId: instanceId,
            protocolVersion: MCPProtocolVersion.latest.rawValue,
            expiresAt: expiresAt
        )
    }

    private func write(_ payload: MCPHandshakePayload, permissions: Int) throws {
        try create(try MCPHandshakeCoding.encoder().encode(payload), permissions: permissions)
    }

    private func create(_ data: Data, permissions: Int) throws {
        try? FileManager.default.removeItem(at: url)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: permissions]
            )
        )
    }

    private func startForeignProcess() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier
        addTeardownBlock {
            kill(pid, SIGTERM)
        }
        return pid
    }
}

@MainActor
final class MCPHandshakeFileTests: XCTestCase {
    func testWritesTheHandshakeReadableOnlyByItsOwner() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)

        file.write(payload())

        let fileMode = try posixPermissions(of: file.url)
        let directoryMode = try posixPermissions(of: directory)
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(directoryMode, 0o700)
    }

    func testWritingLeavesNoStagingFileBehind() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)

        file.write(payload())
        file.write(payload(token: "tp_second"))

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, [MCPHandshakeLocation.fileName])
    }

    func testWritingReplacesTheEarlierCredentialAndKeepsThePermissions() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)

        file.write(payload())
        file.write(payload(token: "tp_second"))

        let loaded = try MCPHandshakeTrust.load(at: file.url, now: Date())
        XCTAssertEqual(loaded.token, "tp_second")
        XCTAssertEqual(try posixPermissions(of: file.url), 0o600)
    }

    func testTheWrittenHandshakeIsTrustedByTheLoader() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)

        file.write(payload())

        let loaded = try MCPHandshakeTrust.load(at: file.url, now: Date())
        XCTAssertEqual(loaded.port, 23_508)
        XCTAssertEqual(loaded.instanceId, "instance-a")
        XCTAssertEqual(loaded.protocolVersion, MCPProtocolVersion.latest.rawValue)
    }

    func testRemovesTheHandshakeThisProcessAndInstanceWrote() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)
        file.write(payload())

        file.removeIfWrittenByThisProcess(instanceId: "instance-a")

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testLeavesAHandshakeWrittenByAnotherInstanceOfThisProcess() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)
        file.write(payload())

        file.removeIfWrittenByThisProcess(instanceId: "instance-b")

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testLeavesAHandshakeWrittenByAnotherProcess() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)
        file.write(payload(pid: 4_242))

        file.removeIfWrittenByThisProcess(instanceId: "instance-a")

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testRemovingWhenNoHandshakeExistsIsSafe() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)

        file.removeIfWrittenByThisProcess(instanceId: "instance-a")
        file.removeIfAbandoned()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testRemovesAnAbandonedHandshakeFromADeadProcess() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)
        file.write(payload(pid: 0x7FFF_FFFE))

        file.removeIfAbandoned()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testRemovesAnExpiredHandshakeEvenFromALiveProcess() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)
        let foreignPid = try startForeignProcess()
        file.write(payload(pid: foreignPid, expiresAt: Date().addingTimeInterval(-1)))

        file.removeIfAbandoned()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testLeavesAnUnexpiredHandshakeHeldByAnotherLiveProcess() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)
        let foreignPid = try startForeignProcess()
        file.write(payload(pid: foreignPid))

        file.removeIfAbandoned()

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testRemovesItsOwnStaleHandshakeBeforeAFreshStart() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)
        file.write(payload())

        file.removeIfAbandoned()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    private func makeDirectoryPath() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-handshake-file-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func posixPermissions(of url: URL) throws -> Int32 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.int32Value ?? -1
    }

    private func payload(
        token: String = "tp_test",
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        expiresAt: Date = Date().addingTimeInterval(3_600)
    ) -> MCPHandshakePayload {
        MCPHandshakePayload(
            port: 23_508,
            token: token,
            pid: pid,
            instanceId: "instance-a",
            protocolVersion: MCPProtocolVersion.latest.rawValue,
            expiresAt: expiresAt
        )
    }

    private func startForeignProcess() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier
        addTeardownBlock {
            kill(pid, SIGTERM)
        }
        return pid
    }
}
