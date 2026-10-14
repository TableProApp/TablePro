//
//  MaterializedViewIndexCompareTests.swift
//  TableProTests
//
//  A materialized view's definition text does not carry its indexes, so a comparison that read
//  the text alone called two views identical when only their indexes differed, and a sync that
//  dropped and created one again left it without the unique index its concurrent refresh needs.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MaterializedViewIndexCompareTests {
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

    @Test
    func anIndexOnlyDifferenceIsADifference() throws {
        let result = try #require(compare(
            source: read(indexes: .read([uniqueId])),
            target: read(indexes: .read([]))
        ))

        #expect(result.status == .differs)
        #expect(result.definitionMatches)
        #expect(result.changes.map(\.description) == ["Add index 'mv_id_idx'"])
        #expect(result.suggestedAction == .alter)
    }

    @Test
    func equalIndexSetsAreIdentical() {
        let result = compare(
            source: read(indexes: .read([uniqueId, customer])),
            target: read(indexes: .read([customer, uniqueId]))
        )

        #expect(result?.status == .identical)
        #expect(result?.changes.count == 0)
    }

    @Test
    func theSameIndexUnderAnotherNameIsANoteRatherThanAChange() {
        let renamed = PluginIndexInfo(name: "mv_id_key", columns: ["id"], isUnique: true)

        let result = compare(source: read(indexes: .read([uniqueId])), target: read(indexes: .read([renamed])))

        #expect(result?.changes.count == 0)
        #expect(result?.notes.count == 1)
    }

    @Test
    func aDefinitionDifferenceStillListsTheIndexChanges() throws {
        let result = try #require(compare(
            source: read("CREATE MATERIALIZED VIEW public.mv AS SELECT id FROM orders;", indexes: .read([uniqueId])),
            target: read(indexes: .read([customer]))
        ))

        #expect(result.status == .differs)
        #expect(!result.definitionMatches)
        #expect(result.sourceIndexes?.map(\.name) == ["mv_id_idx"])
        #expect(result.targetIndexes?.map(\.name) == ["mv_customer_idx"])
    }

    // MARK: - Failed reads

    @Test
    func aFailedIndexReadOnEitherSideIsNotCompared() {
        let sourceFailed = compare(
            source: read(indexes: .failed("permission denied for pg_index")),
            target: read(indexes: .read([uniqueId]))
        )
        let targetFailed = compare(
            source: read(indexes: .read([uniqueId])),
            target: read(indexes: .failed("permission denied for pg_index"))
        )

        for result in [sourceFailed, targetFailed] {
            #expect(result?.comparisonError?.contains("permission denied for pg_index") == true)
            #expect(result?.suggestedAction == .skip)
            #expect(result?.availableActions == [.skip])
            #expect(result?.changes.count == 0, "no DROP INDEX may come from a read that failed")
        }
        #expect(sourceFailed?.comparisonError?.contains("source") == true)
        #expect(targetFailed?.comparisonError?.contains("target") == true)
    }

    @Test
    func aViewWhoseIndexesCouldNotBeReadIsNeverCreated() {
        let result = compare(source: read(indexes: .failed("denied")), target: nil)

        #expect(result?.status == .onlyInSource)
        #expect(result?.comparisonError != nil)
        #expect(result?.suggestedAction == .skip)
    }

    @Test
    func aTargetWhoseIndexesCouldNotBeReadCanStillBeDropped() {
        let result = compare(source: nil, target: read(indexes: .failed("denied")))

        #expect(result?.comparisonError == nil)
        #expect(result?.suggestedAction == .drop)
    }

    // MARK: - Engines that do not carry them

    @Test
    func aTargetThatTakesNoIndexesComparesTheDefinitionAlone() {
        let result = compare(
            source: read(indexes: .read([uniqueId])),
            target: read(indexes: nil),
            targetCarries: false
        )

        #expect(result?.status == .identical)
        #expect(result?.sourceIndexes == nil)
        #expect(result?.showsIndexes == false)
    }

    @Test
    func aSourceThatReportsNoIndexesComparesTheDefinitionAlone() {
        let result = compare(source: read(indexes: nil), target: read(indexes: .read([uniqueId])))

        #expect(result?.status == .identical)
        #expect(result?.sourceIndexes == nil)
    }

    @Test
    func aCreateOnATargetThatTakesNoIndexesSaysTheyAreLeftOut() {
        let result = compare(source: read(indexes: .read([uniqueId])), target: nil, targetCarries: false)

        #expect(result?.notes == [SourceObjectIndexes.notCarriedByTargetNote])
        #expect(result?.sourceIndexes == nil)
    }

    @Test
    func aCreateCarriesTheSourcesIndexes() {
        let result = compare(source: read(indexes: .read([uniqueId, customer])), target: nil)

        #expect(result?.sourceIndexes?.map(\.name) == ["mv_id_idx", "mv_customer_idx"])
        #expect(result?.showsIndexes == true)
    }

    // MARK: - What the definitions pane shows

    @Test
    func theIndexLinesAreDisplayedApartFromTheDefinition() throws {
        let result = try #require(compare(
            source: read(indexes: .read([uniqueId])),
            target: read(indexes: .read([]))
        ))

        #expect(result.sourceIndexLines == ["UNIQUE INDEX mv_id_idx (id) USING BTREE"])
        #expect(result.targetIndexLines == [])
        #expect(!(result.sourceDefinition.joined().contains("INDEX")))
    }

    @Test
    func anIndexOnlyDifferenceCountsItsChangesInTheResultsList() throws {
        let result = try #require(compare(
            source: read(indexes: .read([uniqueId, customer])),
            target: read(indexes: .read([]))
        ))

        let row = CompareResultGrouping.rows(
            from: [result], sortedUsing: [KeyPathComparator(\CompareResultRow.objectName)]
        ).first

        #expect(row?.changeSummary == String(format: String(localized: "%d changes"), 2))
    }
}
