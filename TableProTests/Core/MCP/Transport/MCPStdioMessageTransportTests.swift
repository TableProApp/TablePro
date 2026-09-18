import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPStdioMessageTransportTests: XCTestCase {
    private var stdinPipe: Pipe!
    private var stdoutPipe: Pipe!
    private var logger: RecordingBridgeLogger!

    override func setUp() {
        super.setUp()
        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        logger = RecordingBridgeLogger()
    }

    override func tearDown() {
        stdinPipe = nil
        stdoutPipe = nil
        logger = nil
        super.tearDown()
    }

    func testReadsOneNewlineDelimitedMessagePerLine() async throws {
        let transport = makeTransport()

        let request = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(1), method: "tools/list", params: nil)
        )
        stdinPipe.fileHandleForWriting.write(try JsonRpcCodec.encodeLine(request))

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, request)
        await transport.close()
    }

    func testReadsSeveralMessagesWrittenInOneChunk() async throws {
        let transport = makeTransport()

        let first = JsonRpcMessage.request(JsonRpcRequest(id: .number(1), method: "tools/list", params: nil))
        let second = JsonRpcMessage.notification(
            JsonRpcNotification(method: "notifications/cancelled", params: .object(["requestId": .int(1)]))
        )
        var chunk = try JsonRpcCodec.encodeLine(first)
        chunk.append(try JsonRpcCodec.encodeLine(second))
        stdinPipe.fileHandleForWriting.write(chunk)

        let received = try await collectInbound(transport: transport, count: 2)
        XCTAssertEqual(received[0], first)
        XCTAssertEqual(received[1], second)
        await transport.close()
    }

    func testAMessageSplitAcrossWritesIsReassembled() async throws {
        let transport = makeTransport()

        let request = JsonRpcMessage.request(
            JsonRpcRequest(id: .number(42), method: "prompts/list", params: nil)
        )
        let line = try JsonRpcCodec.encodeLine(request)
        let midpoint = line.count / 2
        stdinPipe.fileHandleForWriting.write(Data(line.prefix(midpoint)))
        try await Task.sleep(for: .milliseconds(50))
        stdinPipe.fileHandleForWriting.write(Data(line.suffix(from: midpoint)))

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, request)
        await transport.close()
    }

    func testACarriageReturnBeforeTheNewlineIsTrimmed() async throws {
        let transport = makeTransport()

        let request = JsonRpcMessage.request(JsonRpcRequest(id: .number(2), method: "ping", params: nil))
        var line = try JsonRpcCodec.encode(request)
        line.append(0x0D)
        line.append(0x0A)
        stdinPipe.fileHandleForWriting.write(line)

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, request)
        await transport.close()
    }

    func testABlankLineIsIgnored() async throws {
        let transport = makeTransport()

        stdinPipe.fileHandleForWriting.write(Data("\n\n".utf8))
        let request = JsonRpcMessage.request(JsonRpcRequest(id: .number(3), method: "tools/list", params: nil))
        stdinPipe.fileHandleForWriting.write(try JsonRpcCodec.encodeLine(request))

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, request)
        await transport.close()
    }

    func testAMalformedLineIsSkippedAndTheStreamCarriesOn() async throws {
        let transport = makeTransport()

        stdinPipe.fileHandleForWriting.write(Data("not json at all\n".utf8))
        let notification = JsonRpcMessage.notification(
            JsonRpcNotification(method: "notifications/cancelled", params: nil)
        )
        stdinPipe.fileHandleForWriting.write(try JsonRpcCodec.encodeLine(notification))

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, notification)
        XCTAssertTrue(logger.entries.contains { $0.level == .warning && $0.message.contains("malformed") })
        await transport.close()
    }

    func testATrailingLineWithoutANewlineIsStillDelivered() async throws {
        let transport = makeTransport()

        let request = JsonRpcMessage.request(JsonRpcRequest(id: .number(9), method: "tools/list", params: nil))
        stdinPipe.fileHandleForWriting.write(try JsonRpcCodec.encode(request))
        try stdinPipe.fileHandleForWriting.close()

        let received = try await firstInbound(transport: transport)
        XCTAssertEqual(received, request)
        await transport.close()
    }

    func testSendWritesOneLineAndNothingElse() async throws {
        let transport = makeTransport()

        let response = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(3), result: .object(["ok": .bool(true)]))
        )
        try await transport.send(response)
        try await Task.sleep(for: .milliseconds(150))

        let written = stdoutPipe.fileHandleForReading.availableData
        XCTAssertFalse(written.isEmpty)
        XCTAssertEqual(written.last, 0x0A)

        let payload = written.dropLast()
        XCTAssertFalse(payload.contains(0x0A), "A stdio message must not contain an embedded newline")
        XCTAssertEqual(try JsonRpcCodec.decode(payload), response)

        await transport.close()
    }

    func testSendsAreFramedOneMessagePerLine() async throws {
        let transport = makeTransport()

        let first = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(1), result: .object([:]))
        )
        let second = JsonRpcMessage.notification(
            JsonRpcNotification(method: "notifications/progress", params: .object(["progress": .double(1.5)]))
        )
        try await transport.send(first)
        try await transport.send(second)
        try await Task.sleep(for: .milliseconds(150))

        let written = stdoutPipe.fileHandleForReading.availableData
        let lines = written
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try JsonRpcCodec.decode(lines[0]), first)
        XCTAssertEqual(try JsonRpcCodec.decode(lines[1]), second)

        await transport.close()
    }

    func testTheInboundStreamFinishesWhenStdinCloses() async throws {
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

    func testSendingAfterCloseThrows() async {
        let transport = makeTransport()
        await transport.close()

        do {
            try await transport.send(.notification(JsonRpcNotification(method: "x", params: nil)))
            XCTFail("Expected a closed transport to refuse a send")
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
        timeout: TimeInterval = 10.0
    ) async throws -> JsonRpcMessage {
        let collected = try await collectInbound(transport: transport, count: 1, timeout: timeout)
        guard let first = collected.first else { throw StdioTestError.timeout }
        return first
    }

    private func collectInbound(
        transport: MCPStdioMessageTransport,
        count: Int,
        timeout: TimeInterval = 10.0
    ) async throws -> [JsonRpcMessage] {
        try await withThrowingTaskGroup(of: [JsonRpcMessage]?.self) { group in
            group.addTask {
                var iterator = transport.inbound.makeAsyncIterator()
                var collected: [JsonRpcMessage] = []
                while collected.count < count {
                    guard let next = try await iterator.next() else { break }
                    collected.append(next)
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
                return nil
            }
            guard let result = try await group.next(), let value = result, value.count == count else {
                group.cancelAll()
                throw StdioTestError.timeout
            }
            group.cancelAll()
            return value
        }
    }
}

private enum StdioTestError: Error {
    case timeout
}

final class RecordingBridgeLogger: MCPBridgeLogger, @unchecked Sendable {
    struct Entry: Sendable {
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
