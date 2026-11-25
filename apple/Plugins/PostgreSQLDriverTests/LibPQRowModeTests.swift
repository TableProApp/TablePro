import CLibPQ
import Foundation
import TableProPluginKit
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LibPQRowModeTests {
    private static let events = "SELECT * FROM events"

    // Every status libpq hands back for one statement, with the rows each held.
    private static func results(of rowCount: Int, chunked: Bool = true) throws -> [(status: ExecStatusType, rows: Int32)] {
        let rows: [[String?]] = (0..<rowCount).map { [String($0)] }
        let server = try LibPQScriptedServer(answer: { query in
            query == Self.events ? .init(columns: [.init(name: "id", type: 23)], rows: rows) : nil
        })
        defer { server.close() }
        server.start()
        let conn = try #require(PQconnectdb("host=127.0.0.1 port=\(server.port) user=postgres dbname=postgres"))
        defer { PQfinish(conn) }
        try #require(PQstatus(conn) == CONNECTION_OK)

        try #require(Self.events.withCString { PQsendQuery(conn, $0) } == 1)
        #expect(LibPQRowMode.enter(conn, chunked: chunked))
        var seen: [(status: ExecStatusType, rows: Int32)] = []
        while let result = PQgetResult(conn) {
            seen.append((PQresultStatus(result), PQntuples(result)))
            PQclear(result)
        }
        return seen
    }

    @Test("Rows arrive in full chunks, then the short rest, then an empty end of rows")
    func rowsArriveInChunks() throws {
        let seen = try Self.results(of: 2 * Int(LibPQRowMode.chunkRows) + 5)

        #expect(seen.map(\.status) == [PGRES_TUPLES_CHUNK, PGRES_TUPLES_CHUNK, PGRES_TUPLES_CHUNK, PGRES_TUPLES_OK])
        #expect(seen.map(\.rows) == [LibPQRowMode.chunkRows, LibPQRowMode.chunkRows, 5, 0])
        #expect(seen.allSatisfy { LibPQRowMode.carriesRows($0.status) || $0.status == PGRES_TUPLES_OK })
    }

    @Test("A read that must not hold more than one raw row takes them one at a time")
    func unchunkedReadTakesSingleRows() throws {
        let seen = try Self.results(of: 3, chunked: false)

        #expect(seen.map(\.status) == [PGRES_SINGLE_TUPLE, PGRES_SINGLE_TUPLE, PGRES_SINGLE_TUPLE, PGRES_TUPLES_OK])
        #expect(seen.map(\.rows) == [1, 1, 1, 0])
    }

    @Test("A statement with no rows ends with the empty result that describes its columns")
    func noRowsEndsEmpty() throws {
        let seen = try Self.results(of: 0)

        #expect(seen.map(\.status) == [PGRES_TUPLES_OK])
        #expect(LibPQPluginConnection.carriesRowDescription(PGRES_TUPLES_OK))
    }

    private static func connected(answering rowCount: Int) async throws -> (LibPQScriptedServer, LibPQPluginConnection) {
        let rows: [[String?]] = (0..<rowCount).map { [String($0)] }
        let server = try LibPQScriptedServer(answer: { query in
            query == Self.events ? .init(columns: [.init(name: "id", type: 23)], rows: rows) : nil
        })
        server.start()
        let connection = LibPQPluginConnection(
            host: "127.0.0.1", port: server.port, user: "postgres", password: nil, database: "postgres"
        )
        try await connection.connect()
        try await connection.finishConnecting()
        return (server, connection)
    }

    @Test("A capped read stops inside a chunk, keeps the cap and reports there was more")
    func cappedReadStopsInsideAChunk() async throws {
        let (server, connection) = try await Self.connected(answering: 40)
        defer { server.close() }
        defer { connection.disconnect() }

        let result = try await connection.boundedQuery(Self.events, rowCap: 20)

        #expect(result.rows.count == 20)
        #expect(result.rows.last == [.text("19")])
        #expect(result.isTruncated)
    }

    @Test("A stream hands over every row of every chunk, in order")
    func streamReadsEveryChunk() async throws {
        let (server, connection) = try await Self.connected(answering: 37)
        defer { server.close() }
        defer { connection.disconnect() }

        var ids: [String] = []
        for try await element in connection.streamQuery(Self.events) {
            if case .rows(let rows) = element { ids += rows.compactMap { $0.first?.asText } }
        }

        #expect(ids == (0..<37).map(String.init))
    }
}
