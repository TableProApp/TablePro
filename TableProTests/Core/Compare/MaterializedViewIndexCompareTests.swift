//
//  MaterializedViewIndexCompareTests.swift
//  TableProTests
//
//  A materialized view's definition text does not carry its indexes, so a comparison that read
//  the text alone called two views identical when only their indexes differed, and a sync that
//  dropped and created one again left it without the unique index its concurrent refresh needs.
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class MaterializedViewIndexCompareTests: XCTestCase {
    private let definition = "CREATE MATERIALIZED VIEW public.mv AS SELECT id, customer FROM orders WITH DATA;"

    private let uniqueId = PluginIndexInfo(name: "mv_id_idx", columns: ["id"], isUnique: true)
    private let customer = PluginIndexInfo(name: "mv_customer_idx", columns: ["customer"])

    private func read(
        _ source: String? = nil,
        schema: String? = "public",
        indexes: ObjectIndexRead?
    ) -> RoutineSourceRead {
        RoutineSourceRead(
            name: "mv", kind: .materializedView, schema: schema, signature: nil,
            source: source ?? definition, indexes: indexes
        )
    }

    private func compare(
        source: RoutineSourceRead?,
        target: RoutineSourceRead?,
        targetCarries: Bool = true
    ) -> CompareObjectResult? {
        SourceObjectDiffEngine(
            sourceDatabaseType: .postgresql,
            targetDatabaseType: .postgresql,
            targetIndexedKinds: targetCarries ? [.materializedView] : []
        )
        .compare(source: source.map { [$0] } ?? [], target: target.map { [$0] } ?? [])
        .first
    }

    // MARK: - Differences

    func testAnIndexOnlyDifferenceIsADifference() throws {
        let result = try XCTUnwrap(compare(
            source: read(indexes: .read([uniqueId])),
            target: read(indexes: .read([]))
        ))

        XCTAssertEqual(result.status, .differs)
        XCTAssertTrue(result.definitionMatches)
        XCTAssertEqual(result.changes.map(\.description), ["Add index 'mv_id_idx'"])
        XCTAssertEqual(result.suggestedAction, .alter)
    }

    func testEqualIndexSetsAreIdentical() {
        let result = compare(
            source: read(indexes: .read([uniqueId, customer])),
            target: read(indexes: .read([customer, uniqueId]))
        )

        XCTAssertEqual(result?.status, .identical)
        XCTAssertEqual(result?.changes.count, 0)
    }

    func testTheSameIndexUnderAnotherNameIsANoteRatherThanAChange() {
        let renamed = PluginIndexInfo(name: "mv_id_key", columns: ["id"], isUnique: true)

        let result = compare(source: read(indexes: .read([uniqueId])), target: read(indexes: .read([renamed])))

        XCTAssertEqual(result?.changes.count, 0)
        XCTAssertEqual(result?.notes.count, 1)
    }

    func testADefinitionDifferenceStillListsTheIndexChanges() throws {
        let result = try XCTUnwrap(compare(
            source: read("CREATE MATERIALIZED VIEW public.mv AS SELECT id FROM orders;", indexes: .read([uniqueId])),
            target: read(indexes: .read([customer]))
        ))

        XCTAssertEqual(result.status, .differs)
        XCTAssertFalse(result.definitionMatches)
        XCTAssertEqual(result.sourceIndexes?.map(\.name), ["mv_id_idx"])
        XCTAssertEqual(result.targetIndexes?.map(\.name), ["mv_customer_idx"])
    }

    // MARK: - Failed reads

    func testAFailedIndexReadOnEitherSideIsNotCompared() {
        let sourceFailed = compare(
            source: read(indexes: .failed("permission denied for pg_index")),
            target: read(indexes: .read([uniqueId]))
        )
        let targetFailed = compare(
            source: read(indexes: .read([uniqueId])),
            target: read(indexes: .failed("permission denied for pg_index"))
        )

        for result in [sourceFailed, targetFailed] {
            XCTAssertEqual(result?.comparisonError?.contains("permission denied for pg_index"), true)
            XCTAssertEqual(result?.suggestedAction, .skip)
            XCTAssertEqual(result?.availableActions, [.skip])
            XCTAssertEqual(result?.changes.count, 0, "no DROP INDEX may come from a read that failed")
        }
        XCTAssertEqual(sourceFailed?.comparisonError?.contains("source"), true)
        XCTAssertEqual(targetFailed?.comparisonError?.contains("target"), true)
    }

    func testAViewWhoseIndexesCouldNotBeReadIsNeverCreated() {
        let result = compare(source: read(indexes: .failed("denied")), target: nil)

        XCTAssertEqual(result?.status, .onlyInSource)
        XCTAssertNotNil(result?.comparisonError)
        XCTAssertEqual(result?.suggestedAction, .skip)
    }

    func testATargetWhoseIndexesCouldNotBeReadCanStillBeDropped() {
        let result = compare(source: nil, target: read(indexes: .failed("denied")))

        XCTAssertNil(result?.comparisonError)
        XCTAssertEqual(result?.suggestedAction, .drop)
    }

    // MARK: - Engines that do not carry them

    func testATargetThatTakesNoIndexesComparesTheDefinitionAlone() {
        let result = compare(
            source: read(indexes: .read([uniqueId])),
            target: read(indexes: nil),
            targetCarries: false
        )

        XCTAssertEqual(result?.status, .identical)
        XCTAssertNil(result?.sourceIndexes)
        XCTAssertEqual(result?.showsIndexes, false)
    }

    func testASourceThatReportsNoIndexesComparesTheDefinitionAlone() {
        let result = compare(source: read(indexes: nil), target: read(indexes: .read([uniqueId])))

        XCTAssertEqual(result?.status, .identical)
        XCTAssertNil(result?.sourceIndexes)
    }

    func testACreateOnATargetThatTakesNoIndexesSaysTheyAreLeftOut() {
        let result = compare(source: read(indexes: .read([uniqueId])), target: nil, targetCarries: false)

        XCTAssertEqual(result?.notes, [SourceObjectIndexes.notCarriedByTargetNote])
        XCTAssertNil(result?.sourceIndexes)
    }

    func testACreateCarriesTheSourcesIndexes() {
        let result = compare(source: read(indexes: .read([uniqueId, customer])), target: nil)

        XCTAssertEqual(result?.sourceIndexes?.map(\.name), ["mv_id_idx", "mv_customer_idx"])
        XCTAssertEqual(result?.showsIndexes, true)
    }

    // MARK: - What the definitions pane shows

    func testTheIndexLinesAreDisplayedApartFromTheDefinition() throws {
        let result = try XCTUnwrap(compare(
            source: read(indexes: .read([uniqueId])),
            target: read(indexes: .read([]))
        ))

        XCTAssertEqual(result.sourceIndexLines, ["UNIQUE INDEX mv_id_idx (id) USING BTREE"])
        XCTAssertEqual(result.targetIndexLines, [])
        XCTAssertFalse(result.sourceDefinition.joined().contains("INDEX"))
    }

    func testAnIndexOnlyDifferenceCountsItsChangesInTheResultsList() throws {
        let result = try XCTUnwrap(compare(
            source: read(indexes: .read([uniqueId, customer])),
            target: read(indexes: .read([]))
        ))

        let row = CompareResultGrouping.rows(
            from: [result], sortedUsing: [KeyPathComparator(\CompareResultRow.objectName)]
        ).first

        XCTAssertEqual(row?.changeSummary, String(format: String(localized: "%d changes"), 2))
    }
}
