@testable import TableProTeradataCore
import Testing

private final class ScriptedTransport: TeradataTransport {
    private var replies: [[UInt8]]
    private var timeouts: [Bool]
    private var stream: [UInt8] = []
    private(set) var sent = 0
    private(set) var closed = false

    // A nil reply is a receive that times out, as `recv` does after 20 seconds.
    init(replies: [[UInt8]?]) {
        self.replies = replies.map { $0 ?? [] }
        timeouts = replies.map { $0 == nil }
    }

    func send(_ bytes: [UInt8]) throws {
        sent += 1
    }

    func receive(_ count: Int) throws -> [UInt8] {
        if stream.isEmpty, !replies.isEmpty {
            let timesOut = timeouts.removeFirst()
            stream = replies.removeFirst()
            if timesOut { throw TeradataWireError.truncated("recv errno 35") }
        }
        guard stream.count >= count else { throw TeradataWireError.truncated("closed") }
        defer { stream.removeFirst(count) }
        return Array(stream.prefix(count))
    }

    func finishConnecting() {}

    func cancel() {}

    func close() {
        closed = true
    }
}

struct TeradataConnectionLossTests {
    private static let config = TeradataConnectionConfig(host: "td.example", username: "dbc", password: "dbc")

    private static func reply(_ parcels: [Parcel]) -> [UInt8] {
        LanMessage(kind: .start, body: parcels.flatMap { $0.encoded() }).encoded()
    }

    @Test("A request that times out gives the session up, so its late reply is never read as the next one's")
    func timeoutGivesTheSessionUp() throws {
        let lateReply = Self.reply([Parcel(.success), Parcel(.endRequest)])
        let transport = ScriptedTransport(replies: [nil, lateReply])
        let connection = TeradataConnection(config: Self.config, transport: transport)

        #expect(throws: TeradataWireError.self) { try connection.execute("SELECT * FROM mallory.notes") }
        #expect(transport.closed)
        #expect(!connection.isConnected)
        #expect(connection.hasLostConnection)

        #expect(throws: TeradataWireError.self) { try connection.execute("SELECT iban FROM finance.payees") }
        #expect(transport.sent == 1)
    }

    @Test("An error the server answers with ends the request and keeps the session")
    func serverErrorKeepsTheSession() throws {
        let failure = Parcel(.failure, body: [UInt8](repeating: 0, count: 8) + [0x0E, 0x3F, 0x00, 0x01, 0x78])
        let transport = ScriptedTransport(replies: [Self.reply([failure]), Self.reply([Parcel(.endRequest)])])
        let connection = TeradataConnection(config: Self.config, transport: transport)

        #expect(throws: TeradataWireError.self) { try connection.execute("SELECT * FROM missing") }
        #expect(connection.isConnected)
        #expect(!connection.hasLostConnection)

        _ = try connection.execute("SELECT 1")
        #expect(transport.sent == 2)
        #expect(!transport.closed)
    }
}
