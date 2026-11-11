import Foundation
@testable import TableProTeradataCore
import Testing

// Replies are read in order; a hook keyed by a reply's index runs just before that reply is read, which is where a
// request is waiting on the server when Stop is pressed.
final class StoppableTransport: TeradataTransport {
    private var replies: [[UInt8]]
    private var stream: [UInt8] = []
    private var repliesRead = 0
    var beforeReply: [Int: () -> Void] = [:]
    private(set) var sent: [LanMessage] = []
    private(set) var shutDown = false
    private(set) var closed = false

    var sentKinds: [UInt8] {
        sent.map { $0.kind }
    }

    init(replies: [[UInt8]]) {
        self.replies = replies
    }

    func send(_ bytes: [UInt8]) throws {
        if shutDown || closed { throw TeradataWireError.cancelled }
        sent.append(LanMessage.decode(
            header: Array(bytes.prefix(LanMessage.headerLength)),
            body: Array(bytes.dropFirst(LanMessage.headerLength))
        ))
    }

    func receive(_ count: Int) throws -> [UInt8] {
        if stream.isEmpty {
            beforeReply.removeValue(forKey: repliesRead)?()
            if shutDown || closed { throw TeradataWireError.cancelled }
            guard !replies.isEmpty else { throw TeradataWireError.truncated("no reply") }
            stream = replies.removeFirst()
            repliesRead += 1
        }
        guard stream.count >= count else { throw TeradataWireError.truncated("closed") }
        defer { stream.removeFirst(count) }
        return Array(stream.prefix(count))
    }

    func finishConnecting() {}

    func cancel() {
        shutDown = true
    }

    func close() {
        closed = true
    }
}

// A server that never answers: a receive waits until the transport is shut down, which the stop's deadline does from
// its own queue.
private final class SilentTransport: TeradataTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let shutDown = DispatchSemaphore(value: 0)
    private var sent: [UInt8] = []
    private var shut = false
    private var received = false
    var onFirstReceive: (() -> Void)?

    var sentKinds: [UInt8] { lock.withLock { sent } }
    var wasShutDown: Bool { lock.withLock { shut } }

    func send(_ bytes: [UInt8]) throws {
        try lock.withLock {
            if shut { throw TeradataWireError.cancelled }
            sent.append(bytes[2])
        }
    }

    func receive(_ count: Int) throws -> [UInt8] {
        let first = lock.withLock { () -> Bool in
            defer { received = true }
            return !received
        }
        if first { onFirstReceive?() }
        _ = shutDown.wait(timeout: .now() + 10)
        throw TeradataWireError.cancelled
    }

    func finishConnecting() {}

    func cancel() {
        lock.withLock { shut = true }
        shutDown.signal()
    }

    func close() {
        cancel()
    }
}

struct TeradataStopTests {
    private static let config = TeradataConnectionConfig(host: "td.example", username: "dbc", password: "dbc")
    private static let ansiConfig = TeradataConnectionConfig(
        host: "td.example", username: "dbc", password: "dbc", transactionMode: .ansi
    )
    private static let start = MessageKind.start.rawValue
    private static let cont = MessageKind.cont.rawValue
    private static let abort = MessageKind.abort.rawValue

    private static func reply(_ parcels: [Parcel]) -> [UInt8] {
        LanMessage(kind: .start, body: parcels.flatMap { $0.encoded() }).encoded()
    }

    private static func failure(code: Int, _ message: String) -> Parcel {
        let text = Array(message.utf8)
        let body = [UInt8](repeating: 0, count: 8)
            + [UInt8(code >> 8), UInt8(code & 0xFF), UInt8(text.count >> 8), UInt8(text.count & 0xFF)] + text
        return Parcel(.failure, body: body)
    }

    private static let finished = reply([Parcel(.success), Parcel(.endRequest)])

    private static func thrown(_ body: () throws -> Void) -> Error? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }

    private static func isCancelled(_ error: Error?) -> Bool {
        guard let wire = error as? TeradataWireError, case .cancelled = wire else { return false }
        return true
    }

    private static func isRolledBack(_ error: Error?) -> Bool {
        guard let wire = error as? TeradataWireError, case .rolledBackByStop = wire else { return false }
        return true
    }

    @Test("A Stop outside a session set to ANSI reads as a cancel")
    func stopOutsideANSIModeIsACancel() throws {
        let aborted = Self.reply([Self.failure(code: 3_110, "The transaction was aborted by the user.")])
        let transport = StoppableTransport(replies: [aborted])
        let connection = TeradataConnection(config: Self.config, transport: transport)
        transport.beforeReply[0] = { connection.cancel() }

        let error = Self.thrown { _ = try connection.execute("SELECT * FROM sales.orders") }

        guard let wire = error as? TeradataWireError, case .cancelled = wire else {
            Issue.record("Expected cancelled, got \(String(describing: error))")
            return
        }
    }

    @Test("Stop while the server works on a request aborts it on the session, which stays logged on and reports the rollback")
    func stopAbortsTheRequestAndKeepsTheSession() throws {
        let aborted = Self.reply([Self.failure(code: 3_110, "The transaction was aborted by the user.")])
        let transport = StoppableTransport(replies: [aborted, Self.finished])
        let connection = TeradataConnection(config: Self.ansiConfig, transport: transport)
        transport.beforeReply[0] = { connection.cancel() }

        let error = Self.thrown { _ = try connection.execute("SELECT * FROM sales.orders CROSS JOIN sales.items") }

        #expect(Self.isRolledBack(error))
        #expect(transport.sentKinds == [Self.start, Self.abort])
        #expect(transport.sent.last?.requestNumber == transport.sent.first?.requestNumber)
        #expect(transport.sent.last?.body == TeradataMessages.abortParcel().encoded())
        #expect(!transport.shutDown)
        #expect(!transport.closed)
        #expect(connection.isConnected)
        #expect(!connection.hasLostConnection)

        _ = try connection.execute("SELECT 1")
        #expect(transport.sentKinds == [Self.start, Self.abort, Self.start])
    }

    @Test("A request that failed on its own before the abort landed keeps its own error")
    func failureOtherThanTheAbortIsReported() throws {
        let missing = Self.reply([Self.failure(code: 3_807, "Object 'sales.orderz' does not exist.")])
        let transport = StoppableTransport(replies: [missing])
        let connection = TeradataConnection(config: Self.config, transport: transport)
        transport.beforeReply[0] = { connection.cancel() }

        let error = Self.thrown { _ = try connection.execute("SELECT * FROM sales.orderz") }

        guard let wire = error as? TeradataWireError, case .server(let code, _) = wire else {
            Issue.record("expected the server's error, got \(String(describing: error))")
            return
        }
        #expect(code == 3_807)
        #expect(connection.isConnected)
    }

    // An export Stop lands here: the abort does not take effect once the server has started answering.
    @Test("Stop while a long answer is being fetched ends the output and keeps the session")
    func stopDuringFetchEndsTheOutput() throws {
        let batch = Self.reply([Parcel(.success)])
        let ended = Self.reply([Parcel(.endRequest)])
        let transport = StoppableTransport(replies: [batch, batch, ended, Self.finished])
        let connection = TeradataConnection(config: Self.config, transport: transport)
        transport.beforeReply[1] = { connection.cancel() }

        let error = Self.thrown { _ = try connection.execute("SELECT * FROM sales.orders") }

        #expect(Self.isCancelled(error))
        #expect(transport.sentKinds == [Self.start, Self.cont, Self.cont])
        #expect(transport.sent.last?.body == TeradataMessages.cancelParcel().encoded())
        #expect(!transport.shutDown)
        #expect(!transport.closed)
        #expect(!connection.hasLostConnection)

        _ = try connection.execute("SELECT 1")
        #expect(transport.sentKinds == [Self.start, Self.cont, Self.cont, Self.start])
    }

    @Test("An output the server keeps sending after the Cancel parcel gives the session up")
    func unendedOutputGivesTheSessionUp() throws {
        let batch = Self.reply([Parcel(.success)])
        let transport = StoppableTransport(replies: [batch, batch, batch])
        let connection = TeradataConnection(config: Self.config, transport: transport)
        transport.beforeReply[1] = { connection.cancel() }

        #expect(Self.thrown { _ = try connection.execute("SELECT * FROM sales.orders") } != nil)
        #expect(transport.closed)
        #expect(connection.hasLostConnection)
    }

    @Test("Stop in a running call before its request goes out refuses the request and keeps the session")
    func stopBeforeTheRequestIsSentRefusesIt() throws {
        let transport = StoppableTransport(replies: [Self.finished])
        let connection = TeradataConnection(config: Self.config, transport: transport)

        connection.beginOperation()
        connection.cancel()
        let error = Self.thrown { _ = try connection.execute("DELETE FROM sales.orders") }
        connection.endOperation()

        #expect(Self.isCancelled(error))
        #expect(transport.sent.isEmpty)
        #expect(connection.isConnected)

        connection.beginOperation()
        _ = try connection.execute("SELECT 1")
        connection.endOperation()
        #expect(transport.sentKinds == [Self.start])
    }

    @Test("A stopped request the server never answers gives the session up after the grace", .timeLimit(.minutes(1)))
    func unansweredStopGivesTheSessionUp() throws {
        let transport = SilentTransport()
        let connection = TeradataConnection(config: Self.config, transport: transport, stopGrace: 0.05)
        transport.onFirstReceive = { connection.cancel() }

        let error = Self.thrown { _ = try connection.execute("SELECT * FROM sales.orders CROSS JOIN sales.items") }

        #expect(Self.isCancelled(error))
        #expect(transport.sentKinds == [Self.start, Self.abort])
        #expect(transport.wasShutDown)
        #expect(connection.hasLostConnection)
    }

    @Test("Stop with no request running sends nothing and keeps the session")
    func stopWhileIdleDoesNothing() throws {
        let transport = StoppableTransport(replies: [Self.finished])
        let connection = TeradataConnection(config: Self.config, transport: transport)

        connection.cancel()
        _ = try connection.execute("SELECT 1")

        #expect(transport.sentKinds == [Self.start])
        #expect(!transport.shutDown)
    }
}
