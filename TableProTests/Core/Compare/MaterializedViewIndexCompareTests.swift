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

@MainActor
final class SourceObjectIndexCarriageTests: XCTestCase {
    func testTheMatrixDecidesWhichKindsCarryIndexes() {
        XCTAssertTrue(SourceObjectIndexes.areCarried(for: .materializedView, by: .postgreSQL))
        XCTAssertFalse(SourceObjectIndexes.areCarried(for: .view, by: .postgreSQL))
        XCTAssertFalse(SourceObjectIndexes.areCarried(for: .materializedView, by: .tablesOnly))
        XCTAssertFalse(SourceObjectIndexes.areCarried(for: .table, by: .postgreSQL))
        XCTAssertFalse(SourceObjectIndexes.areCarried(for: .function, by: .postgreSQL))
    }

    func testPostgreSQLAndPGliteCarryAMaterializedViewsIndexes() {
        XCTAssertEqual(SourceObjectIndexes.carriedKinds(on: .postgresql), [.materializedView])
        XCTAssertEqual(SourceObjectIndexes.carriedKinds(on: .pglite), [.materializedView])
    }

    func testEnginesNobodyHasCuratedCarryNone() {
        XCTAssertEqual(SourceObjectIndexes.carriedKinds(on: .cockroachdb), [])
        XCTAssertEqual(SourceObjectIndexes.carriedKinds(on: .redshift), [])
        XCTAssertEqual(SourceObjectIndexes.carriedKinds(on: DatabaseType(rawValue: "NotARealEngine")), [])
    }
}

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

/// The rule PostgreSQL applies to `REFRESH MATERIALIZED VIEW CONCURRENTLY`, as the index read
/// reports it. Each shape was measured on PostgreSQL 17.11.
final class ConcurrentRefreshIndexRuleTests: XCTestCase {
    private func index(
        unique: Bool = true,
        type: EditableIndexDefinition.IndexType = .btree,
        columns: [String] = ["id"],
        expressions: [String] = [],
        includedColumns: [String] = [],
        whereClause: String? = nil
    ) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: "i", columns: columns, type: type, isUnique: unique, isPrimary: false,
            comment: nil, whereClause: whereClause, expressions: expressions, includedColumns: includedColumns
        )
    }

    func testAPlainUniqueIndexAllowsIt() {
        XCTAssertTrue(ConcurrentRefreshIndexRule.isUsable(index()))
        XCTAssertTrue(ConcurrentRefreshIndexRule.isUsable(index(columns: ["customer", "id"])))
        XCTAssertTrue(ConcurrentRefreshIndexRule.isUsable(index(includedColumns: ["customer"])))
    }

    func testAPredicateAnExpressionOrANonUniqueIndexDoesNot() {
        XCTAssertFalse(ConcurrentRefreshIndexRule.isUsable(index(whereClause: "id > 0")))
        XCTAssertFalse(ConcurrentRefreshIndexRule.isUsable(index(columns: ["(id + 0)"], expressions: ["(id + 0)"])))
        XCTAssertFalse(ConcurrentRefreshIndexRule.isUsable(index(unique: false)))
        XCTAssertFalse(ConcurrentRefreshIndexRule.isUsable(index(type: .gist)))
    }

    func testOneUsableIndexIsEnough() {
        XCTAssertTrue(ConcurrentRefreshIndexRule.allowsConcurrentRefresh([index(unique: false), index()]))
        XCTAssertFalse(ConcurrentRefreshIndexRule.allowsConcurrentRefresh([index(unique: false)]))
        XCTAssertFalse(ConcurrentRefreshIndexRule.allowsConcurrentRefresh([]))
    }
}
