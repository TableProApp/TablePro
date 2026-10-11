import Foundation
@testable import TableProTabularIO
import XCTest

enum JSONFixtures {
    static func index(_ text: String, kind: JSONTableFileKind = .jsonLines) throws -> JSONTableIndex {
        try index(Array(text.utf8), kind: kind)
    }

    static func index(_ bytes: [UInt8], kind: JSONTableFileKind = .jsonLines) throws -> JSONTableIndex {
        try bytes.withUnsafeBufferPointer { try JSONTableIndexer.index($0, fileKind: kind) }
    }

    static func indexError(_ text: String, kind: JSONTableFileKind = .jsonLines) -> Error? {
        do {
            _ = try index(text, kind: kind)
            return nil
        } catch {
            return error
        }
    }

    static func source(_ text: String, kind: JSONTableFileKind = .jsonLines) async throws -> JSONSource {
        try await source(Array(text.utf8), kind: kind)
    }

    static func source(_ bytes: [UInt8], kind: JSONTableFileKind = .jsonLines) async throws -> JSONSource {
        try await JSONSourceBuilder.build(bytes: Data(bytes), fileKind: kind)
    }

    static func buildError(_ text: String, kind: JSONTableFileKind = .jsonLines) async -> Error? {
        do {
            _ = try await source(text, kind: kind)
            return nil
        } catch {
            return error
        }
    }

    static func untouchedRows(of source: JSONSource) -> [JSONOutputRow] {
        (0..<source.rowCount).map { .source($0) }
    }

    static func written(
        _ source: JSONSource,
        rows: [JSONOutputRow],
        keyChanges: [String: JSONMemberChange] = [:]
    ) throws -> String {
        try text(JSONTableWriter(source: source, keyChanges: keyChanges).encoded(rows: rows))
    }

    static func text(_ bytes: [UInt8]) throws -> String {
        try XCTUnwrap(String(bytes: bytes, encoding: .utf8))
    }

    static func texts(_ source: JSONSource, row: Int) -> [String] {
        source.cells(row: row).map(\.text)
    }

    static func kinds(_ source: JSONSource, row: Int) -> [TabularCellKind] {
        source.cells(row: row).map(\.kind)
    }
}
