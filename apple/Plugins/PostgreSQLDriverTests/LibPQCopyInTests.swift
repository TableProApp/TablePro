//
//  LibPQCopyInTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LibPQCopyInTests {
    private static let statement = "COPY public.t (a, b) FROM stdin"

    private struct SourceFailure: Error, Equatable {}

    private final class Pieces: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [Data]
        private var read = 0
        private let failsAfter: Int?
        private let onRead: @Sendable (Int) -> Void

        init(_ pieces: [String], failsAfter: Int? = nil, onRead: @escaping @Sendable (Int) -> Void = { _ in }) {
            remaining = pieces.map { Data($0.utf8) }
            self.failsAfter = failsAfter
            self.onRead = onRead
        }

        var piecesRead: Int {
            lock.withLock { read }
        }

        var data: PluginCopyData {
            PluginCopyData { [self] in try next() }
        }

        private func next() throws -> Data? {
            let (count, piece) = try lock.withLock { () -> (Int, Data?) in
                if let failsAfter, read == failsAfter { throw SourceFailure() }
                read += 1
                return (read, remaining.isEmpty ? nil : remaining.removeFirst())
            }
            onRead(count)
            return piece
        }
    }

    private static func connected(to server: LibPQScriptedServer) async throws -> LibPQPluginConnection {
        let connection = LibPQPluginConnection(
            host: "127.0.0.1", port: server.port, user: "postgres", password: nil, database: "postgres"
        )
        try await connection.connect()
        try await connection.finishConnecting()
        return connection
    }

    private static func server(_ copyIn: LibPQScriptedServer.CopyIn = .init()) throws -> LibPQScriptedServer {
        let server = try LibPQScriptedServer(answer: { query in
            query.hasPrefix("COPY") ? LibPQScriptedServer.Answer(copyIn: copyIn) : nil
        })
        server.start()
        return server
    }

    @Test("The rows reach the server byte for byte in the order read, and the result counts them")
    func rowsArriveWhole() async throws {
        let server = try Self.server()
        defer { server.close() }
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let pieces = Pieces(["1\tone\n2\tt", "wo\n3\t\\N\n", "4\tcaf\u{e9} \u{1F600}\r\n"])
        let result = try await connection.copyFromStandardInput(Self.statement, rows: pieces.data, readOnly: nil)

        #expect(server.copyData == Data("1\tone\n2\ttwo\n3\t\\N\n4\tcaf\u{e9} \u{1F600}\r\n".utf8))
        #expect(result.affectedRows == 4)
        #expect(result.commandTag == "COPY 4")
        #expect(server.copyFailMessages.isEmpty)
        #expect(server.queries.filter { $0.hasPrefix("COPY") } == [Self.statement])
    }

    @Test("No rows still ends the copy, as a COPY of zero rows")
    func noRows() async throws {
        let server = try Self.server()
        defer { server.close() }
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let result = try await connection.copyFromStandardInput(Self.statement, rows: Pieces([]).data, readOnly: nil)

        #expect(server.copyData.isEmpty)
        #expect(result.affectedRows == 0)
    }

    @Test("A source that fails ends the copy with CopyFail and its own error comes back, not the server's echo")
    func sourceFailureEndsTheCopy() async throws {
        let server = try Self.server()
        defer { server.close() }
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let pieces = Pieces(["1\tone\n", "2\ttwo\n"], failsAfter: 1)
        await #expect(throws: SourceFailure.self) {
            _ = try await connection.copyFromStandardInput(Self.statement, rows: pieces.data, readOnly: nil)
        }

        #expect(server.copyData == Data("1\tone\n".utf8))
        #expect(server.copyFailMessages == ["aborted because of read failure"])
        _ = try await connection.executeQuery("SELECT 1")
    }

    @Test("An import's Stop thrown by the source ends the copy as cancelled by the user and comes back as itself")
    func importStopEndsTheCopy() async throws {
        let server = try Self.server()
        defer { server.close() }
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let rows = PluginCopyData { throw PluginImportCancellationError() }
        await #expect(throws: PluginImportCancellationError.self) {
            _ = try await connection.copyFromStandardInput(Self.statement, rows: rows, readOnly: nil)
        }
        #expect(server.copyFailMessages == ["canceled by user"])
    }

    @Test("A Stop between pieces ends the copy with CopyFail and reports cancelled")
    func stopEndsTheCopy() async throws {
        let server = try Self.server()
        defer { server.close() }
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let pieces = Pieces(["1\tone\n", "2\ttwo\n", "3\tthree\n"]) { count in
            if count == 1 { _ = connection.cancellationGate.cancel() }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await connection.copyFromStandardInput(Self.statement, rows: pieces.data, readOnly: nil)
        }

        #expect(server.copyData == Data("1\tone\n".utf8))
        #expect(server.copyFailMessages == ["canceled by user"])
        #expect(pieces.piecesRead == 1)
    }

    @Test("A binary COPY is refused with CopyFail before any piece is read")
    func binaryIsRefused() async throws {
        let server = try Self.server(.init(binary: true))
        defer { server.close() }
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let pieces = Pieces(["PGCOPY"])
        await #expect(throws: LibPQPluginError.self) {
            _ = try await connection.copyFromStandardInput(Self.statement, rows: pieces.data, readOnly: nil)
        }

        #expect(pieces.piecesRead == 0)
        #expect(server.copyData.isEmpty)
        #expect(server.copyFailMessages == ["binary COPY data cannot come from a script"])
    }

    @Test("A row the server refuses fails the COPY with the server's error after every piece was sent")
    func serverRefusalComesBack() async throws {
        let server = try Self.server(.init(failure: .init(sqlState: "22P02", message: "invalid input syntax")))
        defer { server.close() }
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        await #expect {
            _ = try await connection.copyFromStandardInput(Self.statement, rows: Pieces(["x\tbad\n"]).data, readOnly: nil)
        } throws: { error in
            (error as? LibPQPluginError)?.sqlState == "22P02"
        }
        _ = try await connection.executeQuery("SELECT 1")
    }

    @Test("A statement that answers no copy reads as any other, and no piece is read")
    func notACopyReadsAsAStatement() async throws {
        let server = try LibPQScriptedServer(answer: { _ in
            LibPQScriptedServer.Answer(failure: .init(sqlState: "42P01", message: "relation does not exist"))
        })
        server.start()
        defer { server.close() }
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let pieces = Pieces(["1\tone\n"])
        await #expect {
            _ = try await connection.copyFromStandardInput(Self.statement, rows: pieces.data, readOnly: nil)
        } throws: { error in
            (error as? LibPQPluginError)?.sqlState == "42P01"
        }
        #expect(pieces.piecesRead == 0)
    }

    @Test("Under Safe Mode's Read-Only the COPY goes inside a read-only transaction that is rolled back")
    func readOnlyWrapsTheCopy() async throws {
        let server = try LibPQScriptedServer(
            status: { query, _ in
                query.hasPrefix("START TRANSACTION READ ONLY") || query.hasPrefix("COPY")
                    ? LibPQScriptedServer.inTransaction
                    : LibPQScriptedServer.idle
            },
            answer: { query in
                guard query.hasPrefix("COPY") else { return nil }
                return LibPQScriptedServer.Answer(failure: .init(
                    sqlState: "25006", message: "cannot execute COPY FROM in a read-only transaction"
                ))
            }
        )
        server.start()
        defer { server.close() }
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }

        let pieces = Pieces(["1\tone\n"])
        await #expect(throws: (any Error).self) {
            _ = try await connection.copyFromStandardInput(Self.statement, rows: pieces.data, readOnly: .safeMode)
        }

        #expect(Array(server.queries.suffix(3)) == ["START TRANSACTION READ ONLY; SELECT 1", Self.statement, "ROLLBACK"])
        #expect(pieces.piecesRead == 0)
    }
}
