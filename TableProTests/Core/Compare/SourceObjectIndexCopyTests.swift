//
//  SourceObjectIndexCopyTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class SourceObjectIndexCopyTests: XCTestCase {
    private let uniqueId = PluginIndexInfo(name: "mv_id_idx", columns: ["id"], isUnique: true)

    private func read(schema: String? = "public", indexes: ObjectIndexRead?) -> RoutineSourceRead {
        RoutineSourceRead(
            name: "mv", kind: .materializedView, schema: schema, signature: nil,
            source: "CREATE MATERIALIZED VIEW public.mv AS SELECT 1 AS id;", indexes: indexes
        )
    }

    func testIndexesAreWrittenWhereTheTargetTakesThemInTheSameSchema() {
        let decision = SourceObjectIndexCopy.decide(
            for: read(indexes: .read([uniqueId])), targetCarries: true, indexSchema: "public"
        )

        guard case .write(let indexes) = decision else { return XCTFail("expected the indexes, got \(decision)") }
        XCTAssertEqual(indexes.map(\.name), ["mv_id_idx"])
    }

    func testATargetThatTakesNoIndexesGetsTheViewAndANote() {
        XCTAssertEqual(
            SourceObjectIndexCopy.decide(
                for: read(indexes: .read([uniqueId])), targetCarries: false, indexSchema: "public"
            ),
            .leaveOut(SourceObjectIndexes.notCarriedByTargetNote)
        )
    }

    /// A duplicated database is planned against the server's default database, whose schema is
    /// `public`, while the definition names the schema it came from.
    func testIndexStatementsThatWouldNameAnotherSchemaAreLeftOut() {
        let other = SourceObjectIndexCopy.decide(
            for: read(schema: "sales", indexes: .read([uniqueId])), targetCarries: true, indexSchema: "public"
        )
        let unknown = SourceObjectIndexCopy.decide(
            for: read(indexes: .read([uniqueId])), targetCarries: true, indexSchema: nil
        )

        XCTAssertEqual(other, .leaveOut(SourceObjectIndexes.otherSchemaNote))
        XCTAssertEqual(unknown, .leaveOut(SourceObjectIndexes.otherSchemaNote))
    }

    func testAFailedIndexReadRefusesTheViewWithItsReason() {
        let decision = SourceObjectIndexCopy.decide(
            for: read(indexes: .failed("permission denied for pg_index")), targetCarries: true, indexSchema: "public"
        )

        guard case .refuse(let reason) = decision else { return XCTFail("expected a refusal, got \(decision)") }
        XCTAssertTrue(reason.contains("permission denied for pg_index"), reason)
    }

    func testNothingIsSaidWhenThereIsNothingToCarry() {
        XCTAssertEqual(
            SourceObjectIndexCopy.decide(for: read(indexes: .read([])), targetCarries: true, indexSchema: "public"),
            .none
        )
        XCTAssertEqual(
            SourceObjectIndexCopy.decide(for: read(indexes: nil), targetCarries: true, indexSchema: "public"),
            .none
        )
    }
}
