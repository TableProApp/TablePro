//
//  ResultSetComparisonTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private func side(
    _ columns: [String],
    _ rows: [[String?]],
    types: [ColumnType] = [],
    primaryKey: [String] = [],
    truncated: Bool = false
) -> ResultComparisonSide {
    ResultComparisonSide(
        title: "Result",
        detail: "Query 1 (Local)",
        columns: columns,
        columnTypes: types,
        rows: ContiguousArray(rows.enumerated().map { index, values in
            Row(id: .existing(index), values: ContiguousArray(values.map { $0.map(PluginCellValue.text) ?? .null }))
        }),
        isTruncated: truncated,
        primaryKeyColumns: primaryKey
    )
}

private func compare(
    _ left: ResultComparisonSide,
    _ right: ResultComparisonSide,
    key: [String] = []
) throws -> ResultComparison {
    let pairing = ResultColumnPairing(left: left.columns, right: right.columns)
    let keyPairs = key.compactMap { name in pairing.pairs.firstIndex { $0.name == name } }
    return try ResultComparisonEngine.compare(left: left, right: right, pairing: pairing, keyPairs: keyPairs)
}

private func kinds(_ comparison: ResultComparison) -> [ResultRowDifference] {
    comparison.entries.map(\.kind)
}

struct ResultColumnPairingTests {
    @Test("Columns pair by name, and a column on one side only is listed apart")
    func pairsByName() {
        let pairing = ResultColumnPairing(left: ["id", "name", "added"], right: ["name", "id", "removed"])

        #expect(pairing.pairs.map(\.name) == ["id", "name"])
        #expect(pairing.pairs.map(\.left) == [0, 1])
        #expect(pairing.pairs.map(\.right) == [1, 0])
        #expect(pairing.leftOnly == ["added"])
        #expect(pairing.rightOnly == ["removed"])
    }

    @Test("A different case pairs only when no exact spelling is left")
    func caseFallsBack() {
        let pairing = ResultColumnPairing(left: ["ID", "id"], right: ["id", "Id"])

        #expect(pairing.pairs.map(\.left) == [0, 1])
        #expect(pairing.pairs.map(\.right) == [1, 0])
        #expect(pairing.leftOnly.isEmpty)
        #expect(pairing.rightOnly.isEmpty)
    }

    @Test("A repeated name pairs by occurrence")
    func repeatedNamesPairInOrder() {
        let pairing = ResultColumnPairing(left: ["id", "id", "name"], right: ["id", "name", "id"])

        #expect(pairing.pairs.map(\.right) == [0, 2, 1])
    }
}

struct ResultComparisonEngineTests {
    @Test("Keyed rows split into only left, only right, changed and same")
    func keyedComparison() throws {
        let left = side(["id", "name"], [["1", "a"], ["2", "x"], ["4", "d"]])
        let right = side(["id", "name"], [["1", "a"], ["2", "b"], ["3", "c"]])

        let result = try compare(left, right, key: ["id"])

        #expect(kinds(result) == [.same, .changed, .onlyLeft, .onlyRight])
        #expect(result.entries[1].changedPairs == [1])
        #expect(result.entries[1].leftRow == 1)
        #expect(result.entries[1].rightRow == 1)
        #expect(result.entries[3].rightRow == 2)
        #expect(result.differenceCount == 3)
        #expect(result.count(of: .same) == 1)
    }

    @Test("Rows match on the key wherever they sit in each result")
    func keyIgnoresRowOrder() throws {
        let left = side(["id", "name"], [["3", "c"], ["1", "a"]])
        let right = side(["id", "name"], [["1", "a"], ["3", "c"]])

        #expect(kinds(try compare(left, right, key: ["id"])) == [.same, .same])
    }

    @Test("Without a key whole rows match, and a repeated row counts once per copy")
    func wholeRowsCountDuplicates() throws {
        let left = side(["id", "name"], [["1", "a"], ["1", "a"], ["2", "b"]])
        let right = side(["id", "name"], [["1", "a"], ["2", "x"]])

        let result = try compare(left, right)

        #expect(kinds(result) == [.same, .onlyLeft, .onlyLeft, .onlyRight])
        #expect(result.entries[0].rightRow == 0)
        #expect(result.entries[1].leftRow == 1)
        #expect(result.count(of: .changed) == 0)
    }

    @Test("A key repeated on one side is refused and named")
    func duplicateKeyIsRefused() {
        let left = side(["id", "name"], [["1", "a"], ["1", "b"]])
        let right = side(["id", "name"], [["1", "a"]])

        #expect(throws: ResultComparisonError.self) { try compare(left, right, key: ["id"]) }
        do {
            _ = try compare(left, right, key: ["id"])
        } catch {
            #expect(error.localizedDescription.contains("1"))
            #expect(error.localizedDescription.contains("left result"))
        }
    }

    @Test("NULL in a key matches NULL on the other side")
    func nullKeyMatchesNull() throws {
        let left = side(["code", "name"], [[nil, "a"], ["k", "b"]])
        let right = side(["code", "name"], [[nil, "z"], ["k", "b"]])

        let result = try compare(left, right, key: ["code"])

        #expect(kinds(result) == [.changed, .same])
    }

    @Test("A column on one side only is not compared")
    func oneSidedColumnIsIgnored() throws {
        let left = side(["id", "name", "note"], [["1", "a", "left"]])
        let right = side(["id", "name"], [["1", "a"]])

        #expect(kinds(try compare(left, right, key: ["id"])) == [.same])
        #expect(kinds(try compare(left, right)) == [.same])
    }

    @Test("Two spellings of one instant are the same value")
    func timestampsCompareAsInstants() throws {
        let left = side(["id", "at"], [["1", "2026-01-02 10:00:00"]], types: [.integer(rawType: nil), .timestamp(rawType: nil)])
        let right = side(["id", "at"], [["1", "2026-01-02T10:00:00"]], types: [.integer(rawType: nil), .timestamp(rawType: nil)])

        #expect(kinds(try compare(left, right, key: ["id"])) == [.same])
    }

    @Test("Whole-row matching reads two spellings of one instant as the same value")
    func wholeRowTimestamps() throws {
        let types: [ColumnType] = [.integer(rawType: nil), .timestamp(rawType: nil)]
        let left = side(["id", "at"], [["1", "2026-01-02 10:00:00.000001"]], types: types)
        let right = side(["id", "at"], [["1", "2026-01-02T10:00:00.000001"]], types: types)

        #expect(kinds(try compare(left, right)) == [.same])
    }

    @Test("A key holding two spellings of one instant still matches")
    func keyTimestamps() throws {
        let left = side(["at", "v"], [["2026-01-02 10:00:00", "1"]])
        let right = side(["at", "v"], [["2026-01-02T10:00:00", "1"]])

        #expect(kinds(try compare(left, right, key: ["at"])) == [.same])
    }

    @Test("A field the document lacks is not the same as an explicit NULL")
    func absentIsNotNull() throws {
        let left = side(["id", "tag"], [["1", nil]])
        var lacking = left.rows
        lacking[0].absentColumns = [1]
        let right = ResultComparisonSide(title: "Result", detail: "Query", columns: ["id", "tag"], rows: lacking)

        #expect(kinds(try compare(left, right, key: ["id"])) == [.changed])
        #expect(kinds(try compare(left, right)) == [.onlyLeft, .onlyRight])
    }

    @Test("NULL differs from an empty string")
    func nullIsNotEmpty() throws {
        let left = side(["id", "name"], [["1", nil]])
        let right = side(["id", "name"], [["1", ""]])

        #expect(kinds(try compare(left, right, key: ["id"])) == [.changed])
    }

    @Test("The primary key of the left result's table is the default key")
    func defaultKeyIsPrimaryKey() {
        let left = side(["name", "ID"], [], primaryKey: ["id"])
        let right = side(["name", "id"], [])
        let pairing = ResultColumnPairing(left: left.columns, right: right.columns)

        #expect(ResultComparisonEngine.defaultKeyPairs(left: left, right: right, pairing: pairing) == [1])
    }

    @Test("The right result's key is used when the left has none")
    func defaultKeyFallsBackToRight() {
        let left = side(["id", "name"], [])
        let right = side(["id", "name"], [], primaryKey: ["id"])
        let pairing = ResultColumnPairing(left: left.columns, right: right.columns)

        #expect(ResultComparisonEngine.defaultKeyPairs(left: left, right: right, pairing: pairing) == [0])
    }

    @Test("A key with a column one result lacks falls back to whole rows")
    func defaultKeyNeedsEveryColumn() {
        let left = side(["name"], [], primaryKey: ["id"])
        let right = side(["name", "id"], [])
        let pairing = ResultColumnPairing(left: left.columns, right: right.columns)

        #expect(ResultComparisonEngine.defaultKeyPairs(left: left, right: right, pairing: pairing).isEmpty)
    }

    @Test("Two empty results compare to nothing")
    func emptyResults() throws {
        let result = try compare(side(["id"], []), side(["id"], []), key: ["id"])

        #expect(result.entries.isEmpty)
        #expect(result.differenceCount == 0)
    }
}

@MainActor
struct ResultComparisonModelTests {
    private static func candidate(_ id: UUID, _ side: ResultComparisonSide?) -> ResultComparisonCandidate {
        ResultComparisonCandidate(id: id, title: "Result 1: t", group: "This Tab", isPinned: true, read: { side })
    }

    private static func compared(_ model: ResultComparisonModel) async throws -> ResultComparison {
        try await waitUntil { model.comparison != nil }
        return try #require(model.comparison)
    }

    @Test("It compares with the preferred result on the default key")
    func comparesOnOpen() async throws {
        let rightId = UUID()
        let left = side(["id", "name"], [["1", "a"], ["2", "x"]], primaryKey: ["id"])
        let right = side(["id", "name"], [["1", "a"], ["2", "b"]])
        let model = ResultComparisonModel(left: left, preferredRightId: rightId) {
            [Self.candidate(rightId, right)]
        }

        let result = try await Self.compared(model)

        #expect(model.keyPairs == [0])
        #expect(kinds(result) == [.same, .changed])
    }

    @Test("Clearing the key matches whole rows")
    func matchWholeRows() async throws {
        let rightId = UUID()
        let left = side(["id", "name"], [["1", "a"], ["2", "x"]], primaryKey: ["id"])
        let right = side(["id", "name"], [["1", "a"], ["2", "b"]])
        let model = ResultComparisonModel(left: left, preferredRightId: rightId) {
            [Self.candidate(rightId, right)]
        }
        _ = try await Self.compared(model)

        model.matchWholeRows()
        try await waitUntil { model.comparison?.keyPairs.isEmpty == true }

        #expect(kinds(try #require(model.comparison)) == [.same, .onlyLeft, .onlyRight])
    }

    @Test("A result closed before it is read says so")
    func closedResult() {
        let rightId = UUID()
        let model = ResultComparisonModel(left: side(["id"], [["1"]]), preferredRightId: rightId) {
            [Self.candidate(rightId, nil)]
        }

        guard case .idle(.rightClosed) = model.state else {
            Issue.record("Expected the closed state, got \(model.state)")
            return
        }
    }

    @Test("With nothing to compare against it says so")
    func noCandidates() {
        let model = ResultComparisonModel(left: side(["id"], [["1"]]), preferredRightId: nil) { [] }

        guard case .idle(.noCandidates) = model.state else {
            Issue.record("Expected the empty state, got \(model.state)")
            return
        }
    }

    @Test("Results with no column in common are not compared")
    func noCommonColumns() {
        let rightId = UUID()
        let model = ResultComparisonModel(left: side(["a"], [["1"]]), preferredRightId: rightId) {
            [Self.candidate(rightId, side(["b"], [["1"]]))]
        }

        guard case .idle(.noCommonColumns) = model.state else {
            Issue.record("Expected no common columns, got \(model.state)")
            return
        }
    }

    @Test("A duplicate key reports the refusal rather than a comparison")
    func duplicateKeyFails() async throws {
        let rightId = UUID()
        let left = side(["id"], [["1"], ["1"]], primaryKey: ["id"])
        let model = ResultComparisonModel(left: left, preferredRightId: rightId) {
            [Self.candidate(rightId, side(["id"], [["1"]]))]
        }

        try await waitUntil {
            if case .failed = model.state { return true }
            return false
        }
    }

    @Test("Newest result compares with the one before it, any other with the newest")
    func defaultPartner() {
        let ids = [UUID(), UUID(), UUID()]

        #expect(MainContentCoordinator.defaultComparisonPartner(of: ids[2], among: ids) == ids[1])
        #expect(MainContentCoordinator.defaultComparisonPartner(of: ids[0], among: ids) == ids[2])
        #expect(MainContentCoordinator.defaultComparisonPartner(of: ids[0], among: [ids[0]]) == nil)
    }
}
