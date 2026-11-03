import Foundation
@testable import TableProMCP
import TableProMCPTestSupport
import XCTest

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
        try listen(in: directory)
        let socketPath = MCPSocketLocation.primarySocket(in: directory).path

        file.write(payload(socketPath: socketPath))
        file.write(payload(socketPath: socketPath, token: "tp_second"))

        let loaded = try MCPHandshakeTrust.load(at: file.url, now: Date())
        XCTAssertEqual(loaded.token, "tp_second")
        XCTAssertEqual(try posixPermissions(of: file.url), 0o600)
    }

    func testTheWrittenHandshakeIsTrustedByTheLoader() throws {
        let directory = makeDirectoryPath()
        let file = MCPHandshakeFile(directory: directory)
        try listen(in: directory)

        file.write(payload(socketPath: MCPSocketLocation.primarySocket(in: directory).path))

        let loaded = try MCPHandshakeTrust.load(at: file.url, now: Date())
        XCTAssertEqual(loaded.socketPath, MCPSocketLocation.primarySocket(in: directory).path)
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
        let directory = MCPTestSocketFolder.url()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func posixPermissions(of url: URL) throws -> Int32 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.int32Value ?? -1
    }

    // The loader trusts a handshake only while its socket is listening.
    private func listen(in directory: URL) throws {
        try MCPTestSocketFolder.create(directory)
        let listener = MCPUnixSocketListener(path: MCPSocketLocation.primarySocket(in: directory).path) { $0.cancel() }
        try listener.start()
        addTeardownBlock {
            listener.stop()
        }
    }

    private func payload(
        socketPath: String? = nil,
        token: String = "tp_test",
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        expiresAt: Date = Date().addingTimeInterval(3_600)
    ) -> MCPHandshakePayload {
        MCPHandshakePayload(
            socketPath: socketPath ?? "/nonexistent/mcp.sock",
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
