@testable import TableProTeradataCore
import Testing

struct TeradataStreamTests {
    private static let start = MessageKind.start.rawValue
    private static let cont = MessageKind.cont.rawValue
    private static let abort = MessageKind.abort.rawValue
    private static let integer: UInt16 = 496
    private static let char: UInt16 = 452

    private static let numbers = prepInfoX([(integer, 4, "n")])
    private static let finished = reply([Parcel(.success), Parcel(.endRequest)])

    private static func reply(_ parcels: [Parcel]) -> [UInt8] {
        LanMessage(kind: .start, body: parcels.flatMap { $0.encoded() }).encoded()
    }

    private static func u16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    // A PrepInfoX parcel laid out as in TeradataReplyDecodingTests.
    private static func prepInfoX(_ columns: [(type: UInt16, length: Int, name: String)]) -> Parcel {
        var body = [UInt8](repeating: 0, count: 8) + u16(0) + u16(columns.count)
        for column in columns {
            let name = Array(column.name.utf8)
            body += u16(Int(column.type))
            body += (0..<8).map { UInt8(truncatingIfNeeded: column.length >> (8 * (7 - $0))) }
            body += [0, 0]
            body += u16(name.count) + name
            body += u16(0) + u16(0)
        }
        return Parcel(.prepInfoX, body: body)
    }

    private static func number(_ value: Int32) -> Parcel {
        let bits = UInt32(bitPattern: value)
        return Parcel(.record, body: [0x00] + (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8 * (3 - $0))) })
    }

    private static func code(_ text: String) -> Parcel {
        Parcel(.record, body: [0x00] + Array(text.utf8))
    }

    private static func failure(code: Int, _ message: String) -> Parcel {
        let text = Array(message.utf8)
        return Parcel(.failure, body: [UInt8](repeating: 0, count: 8) + u16(code) + u16(text.count) + text)
    }

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

    private static func connection(
        _ replies: [[UInt8]],
        transactionMode: TeradataTransactionMode = .default
    ) -> (TeradataConnection, StoppableTransport) {
        let transport = StoppableTransport(replies: replies)
        let config = TeradataConnectionConfig(
            host: "td.example", username: "dbc", password: "dbc", transactionMode: transactionMode
        )
        return (TeradataConnection(config: config, transport: transport), transport)
    }

    @Test("Each reply's rows reach the consumer before the next Continue goes out")
    func rowsArriveReplyByReply() throws {
        let (connection, transport) = Self.connection([
            Self.reply([Self.numbers, Self.number(1), Self.number(2)]),
            Self.reply([Self.number(3)]),
            Self.reply([Self.number(4), Parcel(.endRequest)]),
        ])
        var headers: [[String]] = []
        var batches: [[[TeradataValue]]] = []
        var sentBeforeEachBatch: [Int] = []

        try connection.stream("SELECT n FROM sales.orders", onColumns: { headers.append($0.map { $0.name }) }, onRows: { rows in
            batches.append(rows)
            sentBeforeEachBatch.append(transport.sent.count)
            return true
        })

        #expect(headers == [["n"]])
        #expect(batches == [[[.integer(1)], [.integer(2)]], [[.integer(3)]], [[.integer(4)]]])
        #expect(sentBeforeEachBatch == [1, 2, 3])
        #expect(transport.sentKinds == [Self.start, Self.cont, Self.cont])
        #expect(transport.sent.dropFirst().allSatisfy { $0.body == TeradataMessages.responseParcel().encoded() })
    }

    @Test("A SELECT that matches no row still describes its columns")
    func emptyResultStillHasColumns() throws {
        let (connection, _) = Self.connection([
            Self.reply([Parcel(.success), Self.numbers, Parcel(.endStatement), Parcel(.endRequest)]),
        ])
        var headers: [[String]] = []
        var batches = 0

        try connection.stream("SELECT n FROM sales.orders WHERE 1 = 0", onColumns: { headers.append($0.map { $0.name }) }, onRows: { _ in
            batches += 1
            return true
        })

        #expect(headers == [["n"]])
        #expect(batches == 0)
    }

    @Test("A statement without a result set still answers, with no columns")
    func statementWithoutResultHasNoColumns() throws {
        let (connection, _) = Self.connection([
            Self.reply([Parcel(.success), Parcel(.endStatement), Parcel(.endRequest)]),
        ])
        var headers: [[String]] = []

        try connection.stream("DELETE FROM sales.orders", onColumns: { headers.append($0.map { $0.name }) }, onRows: { _ in true })

        #expect(headers == [[]])
    }

    @Test("A consumer that wants no more rows ends the output and keeps the session")
    func consumerEndsTheOutput() throws {
        let (connection, transport) = Self.connection([
            Self.reply([Self.numbers, Self.number(1)]),
            Self.reply([Parcel(.endRequest)]),
            Self.finished,
        ])
        var batches = 0

        try connection.stream("SELECT n FROM sales.orders", onColumns: { _ in }, onRows: { _ in
            batches += 1
            return false
        })

        #expect(batches == 1)
        #expect(transport.sentKinds == [Self.start, Self.cont])
        #expect(transport.sent.last?.body == TeradataMessages.cancelParcel().encoded())
        #expect(!transport.shutDown)
        #expect(!connection.hasLostConnection)

        _ = try connection.execute("SELECT 1")
        #expect(transport.sentKinds == [Self.start, Self.cont, Self.start])
    }

    @Test("A failure after some rows throws the server's error and keeps the session")
    func failureAfterRowsThrows() throws {
        let (connection, transport) = Self.connection([
            Self.reply([Self.numbers, Self.number(1)]),
            Self.reply([Self.failure(code: 2_646, "No more spool space in dbc.")]),
            Self.finished,
        ])
        var batches: [[[TeradataValue]]] = []

        let error = Self.thrown {
            try connection.stream("SELECT n FROM sales.orders", onColumns: { _ in }, onRows: { rows in
                batches.append(rows)
                return true
            })
        }

        var code: Int?
        if case .server(let failed, _)? = error as? TeradataWireError { code = failed }
        #expect(code == 2_646)
        #expect(batches == [[[.integer(1)]]])
        #expect(connection.isConnected)
        #expect(!connection.hasLostConnection)

        _ = try connection.execute("SELECT 1")
        #expect(transport.sentKinds == [Self.start, Self.cont, Self.start])
    }

    @Test("Stop between replies ends the output, and the stream ends as cancelled")
    func stopBetweenRepliesEndsTheStream() throws {
        let (connection, transport) = Self.connection([
            Self.reply([Self.numbers, Self.number(1)]),
            Self.reply([Parcel(.endRequest)]),
            Self.finished,
        ])
        var batches = 0

        let error = Self.thrown {
            try connection.stream("SELECT n FROM sales.orders", onColumns: { _ in }, onRows: { _ in
                batches += 1
                connection.cancel()
                return true
            })
        }

        #expect(Self.isCancelled(error))
        #expect(batches == 1)
        #expect(transport.sentKinds == [Self.start, Self.cont])
        #expect(transport.sent.last?.body == TeradataMessages.cancelParcel().encoded())
        #expect(!transport.shutDown)
        #expect(!connection.hasLostConnection)

        _ = try connection.execute("SELECT 1")
        #expect(transport.sentKinds == [Self.start, Self.cont, Self.start])
    }

    @Test("A later statement's records are never read against the first statement's columns")
    func laterStatementKeepsItsOwnColumns() throws {
        let answer = Self.reply([
            Self.numbers, Self.number(1), Parcel(.endStatement),
            Self.prepInfoX([(Self.char, 3, "code")]), Self.code("abc"), Parcel(.endStatement),
            Self.numbers, Self.number(2), Parcel(.endStatement),
            Parcel(.endRequest),
        ])
        let sql = "SELECT n FROM sales.a; SELECT code FROM sales.b; SELECT n FROM sales.c"

        let result = try Self.connection([answer]).0.execute(sql)
        let names = result.columns.map { $0.name }
        #expect(names == ["n"])
        #expect(result.rows == [[.integer(1)], [.integer(2)]])

        var headers: [[String]] = []
        var streamed: [[TeradataValue]] = []
        try Self.connection([answer]).0.stream(sql, onColumns: { headers.append($0.map { $0.name }) }, onRows: { rows in
            streamed += rows
            return true
        })
        #expect(headers == [["n"]])
        #expect(streamed == result.rows)
    }

    @Test("Stop before the first reply aborts an ANSI stream's request, and the stream reports the rollback")
    func abortedStreamReportsTheRollback() throws {
        let (connection, transport) = Self.connection([
            Self.reply([Self.failure(code: 3_110, "The transaction was aborted by the user.")]),
            Self.finished,
        ], transactionMode: .ansi)
        transport.beforeReply[0] = { connection.cancel() }
        var headers = 0

        let error = Self.thrown {
            try connection.stream("SELECT n FROM sales.orders", onColumns: { _ in headers += 1 }, onRows: { _ in true })
        }

        var rolledBack = false
        if case .rolledBackByStop? = error as? TeradataWireError { rolledBack = true }
        #expect(rolledBack)
        #expect(headers == 0)
        #expect(transport.sentKinds == [Self.start, Self.abort])
        #expect(connection.isConnected)
        #expect(!connection.hasLostConnection)
    }

    @Test("A row cap ends the output at the reply that passes it and marks the result cut")
    func rowCapEndsTheOutput() throws {
        let (connection, transport) = Self.connection([
            Self.reply([Self.numbers, Self.number(1), Self.number(2)]),
            Self.reply([Self.number(3), Self.number(4)]),
            Self.reply([Parcel(.endRequest)]),
            Self.finished,
        ])

        let capped = try connection.execute("SELECT n FROM sales.orders", rowCap: 3)

        #expect(capped.isTruncated)
        #expect(capped.resultSet.rows == [[.integer(1)], [.integer(2)], [.integer(3)]])
        #expect(transport.sentKinds == [Self.start, Self.cont, Self.cont])
        #expect(transport.sent.last?.body == TeradataMessages.cancelParcel().encoded())
        #expect(!connection.hasLostConnection)

        _ = try connection.execute("SELECT 1")
        #expect(transport.sentKinds == [Self.start, Self.cont, Self.cont, Self.start])
    }

    @Test("A result with exactly as many rows as the cap is not cut")
    func resultAtTheCapIsComplete() throws {
        let (connection, transport) = Self.connection([
            Self.reply([Self.numbers, Self.number(1), Self.number(2), Parcel(.endRequest)]),
        ])

        let capped = try connection.execute("SELECT n FROM sales.orders", rowCap: 2)

        #expect(!capped.isTruncated)
        #expect(capped.resultSet.rows == [[.integer(1)], [.integer(2)]])
        #expect(transport.sentKinds == [Self.start])
    }
}
