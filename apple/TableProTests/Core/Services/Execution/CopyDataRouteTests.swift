//
//  CopyDataRouteTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

@MainActor
struct CopyDataRouteTests {
    private static func route(_ text: String, sendsBatchesWhole: Bool) -> QueryExecutionRoute? {
        QueryExecutionRoute.resolve(
            QueryBatchPlanner.batches(in: text, model: .sql, grammar: TestGrammar.postgres),
            sendsBatchesWhole: sendsBatchesWhole,
            isPlainQuery: { _ in true }
        )
    }

    @Test("A COPY carrying rows runs statement by statement even alone, where a lone statement takes the single path", arguments: [
        false, true,
    ])
    func copyTakesTheStatementPath(sendsBatchesWhole: Bool) {
        let route = Self.route("COPY t (a, b) FROM stdin;\n1\tone\n\\.\n", sendsBatchesWhole: sendsBatchesWhole)
        guard case .statements(let statements) = route else {
            Issue.record("expected statements, got \(String(describing: route))")
            return
        }
        #expect(statements.map { $0.sql } == ["COPY t (a, b) FROM stdin"])
        #expect(statements.map { $0.copyData } == ["1\tone\n"])

        guard case .single = Self.route("SELECT 1;", sendsBatchesWhole: sendsBatchesWhole) else {
            Issue.record("expected a lone query on the single path")
            return
        }
    }

    @Test("A COPY with no rows still takes the statement path, the one that runs a copy")
    func copyWithoutRowsTakesTheStatementPath() {
        guard case .statements(let statements) = Self.route("COPY t FROM stdin;", sendsBatchesWhole: false) else {
            Issue.record("expected statements")
            return
        }
        #expect(statements.map { $0.copyData } == [""])
    }
}

struct CopyDataPiecesTests {
    private static func pieces(of text: String) throws -> [Data] {
        let rows = CopyDataPieces.reading(text)
        var pieces: [Data] = []
        while let piece = try rows.nextPiece() {
            pieces.append(piece)
        }
        #expect(try rows.nextPiece() == nil)
        return pieces
    }

    @Test("No rows make no piece")
    func noRows() throws {
        #expect(try Self.pieces(of: "").isEmpty)
    }

    @Test("Rows go as UTF-8 in pieces of at most 64 KiB, cut wherever the limit falls, even inside a character")
    func piecesCutAnywhere() throws {
        let text = "12\t" + String(repeating: "é", count: 70_000) + "\n"

        let pieces = try Self.pieces(of: text)

        #expect(pieces.map { $0.count } == [65_536, 65_536, 8_932])
        #expect(Data(pieces.joined()) == Data(text.utf8))
        let first = try #require(pieces.first)
        #expect(String(data: first, encoding: .utf8) == nil)
    }
}
