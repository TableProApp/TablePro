import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPStdioMessageTransportTests: XCTestCase {
    private var stdinPipe: Pipe!
    private var stdoutPipe: Pipe!
    private var logger: FakeBridgeLogger!

    override func setUp() {
        super.setUp()
        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        logger = FakeBridgeLogger()
    }

    override func tearDown() {
        stdinPipe = nil
        stdoutPipe = nil
        logger = nil
        super.tearDown()
    }

    func testReceivesValidLine() async throws {
        let transport = makeTransport()

        let message = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(1), method: "ping", params: nil)
        )
        let line = try JsonRpcCodec.encodeLine(message)
        stdinPipe.fileHandleForWriting.write(line)

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, message)
        await transport.close()
    }

    func testSkipsMalformedLineAndContinues() async throws {
        let transport = makeTransport()

        stdinPipe.fileHandleForWriting.write(Data("not json at all\n".utf8))

        let valid = JsonRpcMessage.notification(
            JsonRpcNotification(method: "notifications/initialized", params: nil)
        )
        try stdinPipe.fileHandleForWriting.write(contentsOf: try JsonRpcCodec.encodeLine(valid))

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, valid)
        XCTAssertTrue(logger.entries.contains { $0.level == .warning && $0.message.contains("malformed") })
        await transport.close()
    }

    func testHandlesBytesSplitAcrossWrites() async throws {
        let transport = makeTransport()

        let message = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(42), method: "tools/list", params: nil)
        )
        let line = try JsonRpcCodec.encodeLine(message)
        let half = line.count / 2
        stdinPipe.fileHandleForWriting.write(Data(line.prefix(half)))
        try await Task.sleep(nanoseconds: 50_000_000)
        stdinPipe.fileHandleForWriting.write(Data(line.suffix(from: half)))

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, message)
        await transport.close()
    }

    func testSendWritesValidJsonRpcLineToStdout() async throws {
        let transport = makeTransport()

        let message = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(3), result: .object(["ok": .bool(true)]))
        )
        try await transport.send(message)

        try await Task.sleep(nanoseconds: 50_000_000)

        let written = stdoutPipe.fileHandleForReading.availableData
        XCTAssertFalse(written.isEmpty)
        XCTAssertEqual(written.last, 0x0A)
        let trimmed = written.dropLast()
        let decoded = try JsonRpcCodec.decode(trimmed)
        XCTAssertEqual(decoded, message)

        await transport.close()
    }

    func testInboundFinishesOnEof() async throws {
        let transport = makeTransport()

        try stdinPipe.fileHandleForWriting.close()

        var iterator = transport.inbound.makeAsyncIterator()
        let value = try await iterator.next()
        XCTAssertNil(value)

        await transport.close()
    }

    func testCloseIsIdempotent() async {
        let transport = makeTransport()
        await transport.close()
        await transport.close()
    }

    func testSendAfterCloseThrows() async {
        let transport = makeTransport()
        await transport.close()

        let message = JsonRpcMessage.notification(
            JsonRpcNotification(method: "ping", params: nil)
        )
        do {
            try await transport.send(message)
            XCTFail("Expected throw")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    private func makeTransport() -> MCPStdioMessageTransport {
        MCPStdioMessageTransport(
            stdin: stdinPipe.fileHandleForReading,
            stdout: stdoutPipe.fileHandleForWriting,
            errorLogger: logger
        )
    }

    private func firstInbound(
        transport: MCPStdioMessageTransport,
        timeout: TimeInterval = 2.0
    ) async throws -> JsonRpcMessage {
        try await withThrowingTaskGroup(of: JsonRpcMessage?.self) { group in
            group.addTask {
                var iterator = transport.inbound.makeAsyncIterator()
                return try await iterator.next()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            guard let result = try await group.next(), let value = result else {
                group.cancelAll()
                throw TestError.timeout
            }
            group.cancelAll()
            return value
        }
    }
}

private enum TestError: Error {
    case timeout
}

private final class FakeBridgeLogger: MCPBridgeLogger, @unchecked Sendable {
    struct Entry {
        let level: MCPBridgeLogLevel
        let message: String
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func log(_ level: MCPBridgeLogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Entry(level: level, message: message))
    }
}
