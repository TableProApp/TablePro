//
//  CompareDriverRowCutTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct CompareDriverRowCutTests {
    private func stream(rowLimit: Int?, ids: [Int]) -> AsyncThrowingStream<PluginStreamElement, Error> {
        var header = PluginStreamHeader(columns: ["id", "name"], columnTypeNames: ["integer", "text"])
        header.rowLimit = rowLimit
        let rows: [PluginRow] = ids.map { [.text(String($0)), .text("n")] }
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(header))
            continuation.yield(.rows(rows))
            continuation.finish()
        }
    }

    private func targetRows(_ ids: [Int]) -> [DataRow] {
        ids.map { DataRow(values: ["id": .text(String($0)), "name": .text("n")]) }
    }

    private func engine() -> DataDiffEngine {
        DataDiffEngine(
            options: DataCompareOptions(),
            shape: DataComparisonShape(
                keyColumns: ["id"],
                keyOrders: [.numeric],
                comparedColumns: ["name"],
                digestColumns: ["id", "name"]
            )
        )
    }

    @Test("A stream that ends at the limit its driver declares reads as cut there")
    func streamEndingAtTheDeclaredLimitIsCut() async throws {
        let provider = StreamingRowProvider(stream: stream(rowLimit: 2, ids: [1, 2]))
        while try await provider.nextRow() != nil {}

        #expect(provider.endedAtRowLimit)
        #expect(provider.driverRowCut == 2)
    }

    @Test("A stream that ends short of its declared limit read every row")
    func streamShortOfTheDeclaredLimitIsWhole() async throws {
        let provider = StreamingRowProvider(stream: stream(rowLimit: 5, ids: [1, 2]))
        while try await provider.nextRow() != nil {}

        #expect(!provider.endedAtRowLimit)
        #expect(provider.driverRowCut == nil)
    }

    // A HANA source stops at 5,000,000 rows: every target row past them read as a delete, and a sync removed them.
    @Test("A source the driver cut short reports no deletes past the cut")
    func cutSourceProducesNoDeletesPastIt() async throws {
        let summary = try await engine().compare(
            source: StreamingRowProvider(stream: stream(rowLimit: 2, ids: [1, 2])),
            target: ArrayRowProvider(rows: targetRows([1, 2, 3, 4]))
        )

        #expect(summary.deleteCount == 0)
        #expect(summary.identicalCount == 2)
        #expect(summary.stoppedAtRowLimit)
        #expect(summary.sourceRowCut == 2)
        #expect(summary.targetRowCut == nil)
        #expect(summary.resumeKey == [.text("2")])
    }

    @Test("A target the driver cut short reports no inserts past the cut")
    func cutTargetProducesNoInsertsPastIt() async throws {
        let summary = try await engine().compare(
            source: ArrayRowProvider(rows: targetRows([1, 2, 3, 4])),
            target: StreamingRowProvider(stream: stream(rowLimit: 2, ids: [1, 2]))
        )

        #expect(summary.insertCount == 0)
        #expect(summary.targetRowCut == 2)
        #expect(summary.stoppedAtRowLimit)
    }

    @Test("The cut is named in the wording the export uses")
    func cutWordingMatchesTheExport() {
        #expect(StreamRowCutWarning.text(table: "orders", limit: 5_000_000).hasPrefix("orders: "))
    }
}
