//
//  StructureChangeGuardTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro
import TableProPluginKit

struct StructureChangeGuardTests {
    private func column(
        _ name: String,
        _ dataType: String = "int",
        comment: String? = nil,
        collation: String? = nil
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: name, dataType: dataType, isNullable: true, defaultValue: nil,
            autoIncrement: false, unsigned: false, comment: comment, collation: collation,
            onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: false
        )
    }

    private func snapshot(
        columns: [EditableColumnDefinition],
        collation: String? = nil
    ) -> TableStructureSnapshot {
        TableStructureSnapshot(name: "orders", schema: "shop", columns: columns, collation: collation)
    }

    private func table(
        status: TableDiffStatus = .differs,
        changes: [SchemaChange] = []
    ) -> CompareObjectResult {
        CompareObjectResult(
            identity: CompareObjectIdentity(kind: .table, schema: "shop", name: "orders"),
            status: status,
            changes: changes
        )
    }

    private func view(definition: [String]) -> CompareObjectResult {
        CompareObjectResult(
            identity: CompareObjectIdentity(kind: .view, schema: "shop", name: "recent_orders"),
            status: .onlyInSource,
            sourceDefinition: definition
        )
    }

    private func inputs(
        _ results: [CompareObjectResult],
        action: TableSyncAction,
        snapshot: TableStructureSnapshot? = nil
    ) -> [String: StructureGenerationInput] {
        StructureChangeGuard.inputs(
            for: results,
            actions: { _ in action },
            sourceSnapshots: snapshot.map { ["shop.orders": $0] } ?? [:]
        )
    }

    // MARK: - Alter

    @Test
    func anAlterWhoseChangesStillMatchIsAllowed() {
        let result = table(changes: [.addColumn(column("total"))])

        #expect(StructureChangeGuard.refusal(
                expected: inputs([result], action: .alter),
                actual: inputs([result], action: .alter)
            ) == nil)
    }

    @Test
    func anAlterWhoseChangeListMovedIsRefused() {
        let expected = inputs([table(changes: [.addColumn(column("total"))])], action: .alter)
        let actual = inputs([table(changes: [.addColumn(column("total", "decimal(10,2)"))])], action: .alter)

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    // MARK: - Create

    /// `SchemaSyncScriptBuilder` renders the snapshot raw, so the guard has to compare it raw. Two
    /// tables the comparison calls identical under its own options still produce different DDL.
    @Test
    func aCreateWhoseSnapshotDiffersOnlyByCollationIsRefused() {
        let result = table(status: .onlyInSource)
        let expected = inputs([result], action: .create, snapshot: snapshot(columns: [column("id")]))
        let actual = inputs(
            [result], action: .create, snapshot: snapshot(columns: [column("id")], collation: "utf8mb4_bin")
        )

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    @Test
    func aCreateWhoseSnapshotDiffersOnlyByAColumnCommentIsRefused() {
        let result = table(status: .onlyInSource)
        let expected = inputs([result], action: .create, snapshot: snapshot(columns: [column("id")]))
        let actual = inputs(
            [result], action: .create, snapshot: snapshot(columns: [column("id", comment: "the key")])
        )

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    @Test
    func aCreateWhoseSourceTableIsGoneIsRefused() {
        let result = table(status: .onlyInSource)
        let expected = inputs([result], action: .create, snapshot: snapshot(columns: [column("id")]))

        #expect(StructureChangeGuard.refusal(expected: expected, actual: inputs([result], action: .create)) != nil)
    }

    // MARK: - Drop

    @Test
    func aDropOfATableThatCameBackIsRefused() {
        let expected = inputs([table(status: .onlyInTarget)], action: .drop)
        let actual = inputs([table(status: .differs)], action: .drop)

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    @Test
    func aDropOfATableThatIsNoLongerInTheReportIsRefused() {
        let expected = inputs([table(status: .onlyInTarget)], action: .drop)

        #expect(StructureChangeGuard.refusal(expected: expected, actual: [:]) != nil)
    }

    // MARK: - Source-defined objects

    /// `SourceObjectSyncBuilder` writes `sourceDefinition` verbatim, while the comparison reads it
    /// through a normalizer that lowercases the body. A guard built on the normalized text would
    /// pass a stale CREATE VIEW for an edit that only changed a literal's case.
    @Test
    func aViewBodyDifferingOnlyInTheCaseOfALiteralIsRefused() {
        let expected = inputs([view(definition: ["SELECT 'Paid' AS state"])], action: .create)
        let actual = inputs([view(definition: ["SELECT 'PAID' AS state"])], action: .create)

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    @Test
    func anUnchangedViewIsAllowed() {
        let result = view(definition: ["SELECT 1"])

        #expect(StructureChangeGuard.refusal(
                expected: inputs([result], action: .create),
                actual: inputs([result], action: .create)
            ) == nil)
    }

    // MARK: - A materialized view's indexes

    private func matviewIndex(_ name: String, unique: Bool = false) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: ["id"], type: .btree, isUnique: unique, isPrimary: false, comment: nil
        )
    }

    private func matview(
        changes: [SchemaChange] = [],
        sourceIndexes: [EditableIndexDefinition]?,
        definitionMatches: Bool = true
    ) -> CompareObjectResult {
        CompareObjectResult(
            identity: CompareObjectIdentity(kind: .materializedView, schema: "shop", name: "totals"),
            status: .differs,
            changes: changes,
            sourceDefinition: ["CREATE MATERIALIZED VIEW shop.totals AS SELECT 1 AS id"],
            sourceIndexes: sourceIndexes,
            definitionMatches: definitionMatches
        )
    }

    @Test
    func twoReadsOfAnUnchangedMaterializedViewAreAllowed() {
        let read = {
            self.matview(
                changes: [.addIndex(self.matviewIndex("totals_id_idx"))],
                sourceIndexes: [self.matviewIndex("totals_id_idx")]
            )
        }

        #expect(StructureChangeGuard.refusal(
            expected: inputs([read()], action: .alter), actual: inputs([read()], action: .alter)
        ) == nil)
    }

    @Test
    func aSourceIndexAddedAfterComparingRefusesTheScript() {
        let expected = inputs([matview(sourceIndexes: [matviewIndex("totals_id_idx")])], action: .create)
        let actual = inputs(
            [matview(sourceIndexes: [matviewIndex("totals_id_idx"), matviewIndex("totals_key", unique: true)])],
            action: .create
        )

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    @Test
    func aTargetIndexChangedAfterComparingRefusesAnIndexOnlyAlter() {
        let expected = inputs(
            [matview(changes: [.deleteIndex(matviewIndex("totals_old_idx"))], sourceIndexes: [])], action: .alter
        )
        let actual = inputs(
            [matview(changes: [.deleteIndex(matviewIndex("totals_other_idx"))], sourceIndexes: [])], action: .alter
        )

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    /// An index-only alter keeps the view and its rows, and a definition that moved since would
    /// turn it into a DROP and CREATE the user never reviewed.
    @Test
    func aDefinitionThatStoppedMatchingRefusesAnIndexOnlyAlter() {
        let expected = inputs([matview(sourceIndexes: [], definitionMatches: true)], action: .alter)
        let actual = inputs([matview(sourceIndexes: [], definitionMatches: false)], action: .alter)

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    // MARK: - Two reads of the same tables

    private func ordersRead(
        totalType: String = "decimal(10,2)",
        shapeSpelling: String = "public.geometry(Point,4326)",
        extraColumns: [PluginColumnInfo] = [],
        extraIndexes: [PluginIndexInfo] = []
    ) -> TableStructureRead {
        TableStructureRead(
            table: PluginTableInfo(name: "orders", schema: "shop", comment: nil),
            columns: [
                PluginColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true),
                PluginColumnInfo(name: "region_id", dataType: "int"),
                PluginColumnInfo(name: "country", dataType: "char(2)"),
                PluginColumnInfo(name: "total", dataType: totalType, comment: "gross"),
                PluginColumnInfo(
                    name: "shape",
                    dataType: "geometry",
                    generationExpression: nil,
                    generationKind: nil,
                    ddlSpelling: shapeSpelling,
                    ddlDefault: nil,
                    ddlGenerationExpression: nil
                )
            ] + extraColumns,
            indexes: [
                PluginIndexInfo(name: "orders_pkey", columns: ["id"], isUnique: true, isPrimary: true),
                PluginIndexInfo(name: "orders_region_idx", columns: ["region_id", "country"])
            ] + extraIndexes,
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_region_fkey", column: "region_id", referencedTable: "regions",
                    referencedColumn: "id", referencedSchema: "shop", onDelete: "cascade"
                ),
                PluginForeignKeyInfo(
                    name: "orders_region_fkey", column: "country", referencedTable: "regions",
                    referencedColumn: "country", referencedSchema: "shop", onDelete: "cascade"
                )
            ],
            metadata: nil,
            failure: nil
        )
    }

    private func legacyOrdersRead(totalType: String = "decimal(8,2)") -> TableStructureRead {
        TableStructureRead(
            table: PluginTableInfo(name: "orders", schema: "shop", comment: nil),
            columns: [
                PluginColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true),
                PluginColumnInfo(name: "region_id", dataType: "int"),
                PluginColumnInfo(name: "country", dataType: "char(2)"),
                PluginColumnInfo(name: "total", dataType: totalType, comment: "gross"),
                PluginColumnInfo(name: "notes", dataType: "text")
            ],
            indexes: [
                PluginIndexInfo(name: "orders_pkey", columns: ["id"], isUnique: true, isPrimary: true),
                PluginIndexInfo(name: "orders_total_idx", columns: ["total"])
            ],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_owner_fkey", column: "region_id", referencedTable: "owners",
                    referencedColumn: "id", referencedSchema: "shop"
                )
            ],
            metadata: nil,
            failure: nil
        )
    }

    /// The same steps `CompareRunner` takes from a read to the values the guard is handed, run on
    /// reads taken separately, as the comparison and the script build take theirs.
    private func inputs(
        comparing source: [TableStructureRead],
        with target: [TableStructureRead],
        action: TableSyncAction
    ) -> [String: StructureGenerationInput] {
        let sourceSnapshots = source.compactMap { $0.snapshot }
        let report = StructureDiffEngine().compare(
            source: sourceSnapshots, target: target.compactMap { $0.snapshot }
        )
        return StructureChangeGuard.inputs(
            for: report.results.map { CompareObjectResult.from($0) },
            actions: { _ in action },
            sourceSnapshots: Dictionary(
                sourceSnapshots.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first }
            )
        )
    }

    @Test
    func aCreateFromTwoReadsOfAnUnchangedTableIsAllowed() {
        let expected = inputs(comparing: [ordersRead()], with: [], action: .create)
        let actual = inputs(comparing: [ordersRead()], with: [], action: .create)

        let snapshot = expected.values.first?.sourceSnapshot
        #expect(expected.count == 1)
        #expect(snapshot?.columns.count == 5)
        #expect(snapshot?.indexes.count == 2)
        #expect(snapshot?.foreignKeys.first?.columns == ["region_id", "country"])
        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) == nil)
    }

    @Test
    func anAlterFromTwoReadsOfAnUnchangedPairIsAllowed() {
        let expected = inputs(comparing: [ordersRead()], with: [legacyOrdersRead()], action: .alter)
        let actual = inputs(comparing: [ordersRead()], with: [legacyOrdersRead()], action: .alter)

        #expect(expected.values.first?.changes.map(\.description) == [
                "Modify column 'total' to 'total'",
                "Add column 'shape'",
                "Delete column 'notes'",
                "Add index 'orders_region_idx'",
                "Delete index 'orders_total_idx'",
                "Add foreign key 'orders_region_fkey'",
                "Delete foreign key 'orders_owner_fkey'"
            ])
        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) == nil)
    }

    @Test
    func aCreateWhoseSecondReadGainedAColumnIsRefused() {
        let expected = inputs(comparing: [ordersRead()], with: [], action: .create)
        let actual = inputs(
            comparing: [ordersRead(extraColumns: [PluginColumnInfo(name: "discount", dataType: "int")])],
            with: [],
            action: .create
        )

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    /// The catalog spelling is private state the snapshot carries into `CREATE TABLE`, so it has to
    /// be compared like every public field.
    @Test
    func aCreateWhoseSecondReadSpellsATypeDifferentlyIsRefused() {
        let expected = inputs(comparing: [ordersRead()], with: [], action: .create)
        let actual = inputs(
            comparing: [ordersRead(shapeSpelling: "public.geometry(Point,3857)")], with: [], action: .create
        )

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    @Test
    func aCreateWhoseSecondReadSpellsACollationDifferentlyIsRefused() {
        let collatedRead = { (spelling: String) in
            self.ordersRead(extraColumns: [
                PluginColumnInfo(
                    name: "code", dataType: "text", collation: "Case Insens", generationExpression: nil,
                    generationKind: nil, ddlSpelling: "text", ddlDefault: nil, ddlGenerationExpression: nil,
                    ddlCollation: spelling, classificationTypeName: nil
                )
            ])
        }
        let expected = inputs(comparing: [collatedRead(#"app."Case Insens""#)], with: [], action: .create)
        let unchanged = inputs(comparing: [collatedRead(#"app."Case Insens""#)], with: [], action: .create)
        let respelled = inputs(comparing: [collatedRead(#"shared."Case Insens""#)], with: [], action: .create)

        #expect(expected.values.first?.sourceSnapshot?.columns.last?.ddlCollation == #"app."Case Insens""#)
        #expect(StructureChangeGuard.refusal(expected: expected, actual: unchanged) == nil)
        #expect(StructureChangeGuard.refusal(expected: expected, actual: respelled) != nil)
    }

    @Test
    func aCreateWhoseSecondReadDescribesAnIndexDifferentlyIsRefused() {
        let keys = "USING btree (lower((country)::text))"
        let predicate = "(total > (0)::numeric)"
        let expressions = ["lower(country)"]
        let included = ["total"]
        let indexedRead = { (keySpelling: String, whereSpelling: String, keyExpressions: [String], stored: [String]) in
            self.ordersRead(extraIndexes: [
                PluginIndexInfo(
                    name: "orders_country_idx", columns: ["lower(country)"], whereClause: "total > 0",
                    expressions: keyExpressions, includedColumns: stored,
                    ddlMethodAndKeys: keySpelling, ddlWhereClause: whereSpelling
                )
            ])
        }
        let expected = inputs(
            comparing: [indexedRead(keys, predicate, expressions, included)], with: [], action: .create
        )
        let unchanged = inputs(
            comparing: [indexedRead(keys, predicate, expressions, included)], with: [], action: .create
        )
        let collatedKeys = #"USING btree (lower((country)::text) COLLATE "C")"#
        let differingReads: [(String, TableStructureRead)] = [
            ("key spelling", indexedRead(collatedKeys, predicate, expressions, included)),
            ("predicate spelling", indexedRead(keys, "(total > 0::numeric)", expressions, included)),
            ("expressions", indexedRead(keys, predicate, [], included)),
            ("INCLUDE columns", indexedRead(keys, predicate, expressions, included + ["region_id"]))
        ]

        let index = expected.values.first?.sourceSnapshot?.indexes.last
        #expect(index?.expressions == expressions)
        #expect(index?.includedColumns == included)
        #expect(index?.ddlMethodAndKeys == keys)
        #expect(index?.ddlWhereClause == predicate)
        #expect(StructureChangeGuard.refusal(expected: expected, actual: unchanged) == nil)
        for (label, read) in differingReads {
            let actual = inputs(comparing: [read], with: [], action: .create)
            #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil, Comment(rawValue: label))
        }
    }

    @Test
    func aSyncWhoseSecondReadReportsAnotherIndexTypeIsRefused() {
        let typedRead = { (type: String) in
            self.ordersRead(extraIndexes: [
                PluginIndexInfo(name: "orders_country_idx", columns: ["country"], type: type)
            ])
        }
        let expectedCreate = inputs(comparing: [typedRead("hnsw")], with: [], action: .create)
        let expectedAlter = inputs(comparing: [typedRead("hnsw")], with: [typedRead("ivfflat")], action: .alter)

        #expect(expectedCreate.values.first?.sourceSnapshot?.indexes.last?.type.rawValue == "HNSW")
        #expect(StructureChangeGuard.refusal(
            expected: expectedCreate,
            actual: inputs(comparing: [typedRead("HNSW")], with: [], action: .create)
        ) == nil)
        #expect(StructureChangeGuard.refusal(
            expected: expectedCreate,
            actual: inputs(comparing: [typedRead("ivfflat")], with: [], action: .create)
        ) != nil)
        #expect(StructureChangeGuard.refusal(
            expected: expectedAlter,
            actual: inputs(comparing: [typedRead("hnsw")], with: [typedRead("ivfflat")], action: .alter)
        ) == nil)
        #expect(StructureChangeGuard.refusal(
            expected: expectedAlter,
            actual: inputs(comparing: [typedRead("hnsw")], with: [typedRead("bloom")], action: .alter)
        ) != nil)
    }

    @Test
    func anAlterWhoseTargetColumnMovedBetweenReadsIsRefused() {
        let expected = inputs(comparing: [ordersRead()], with: [legacyOrdersRead()], action: .alter)
        let actual = inputs(
            comparing: [ordersRead()], with: [legacyOrdersRead(totalType: "decimal(9,2)")], action: .alter
        )

        #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) != nil)
    }

    @Test
    func everyKindOfChangeIsComparedWithoutTheIdentityItWasReadWith() {
        let index = { (name: String) in
            EditableIndexDefinition(
                id: UUID(), name: name, columns: ["total"], type: .btree, isUnique: false,
                isPrimary: false, comment: nil
            )
        }
        let foreignKey = { (name: String) in
            EditableForeignKeyDefinition(
                id: UUID(), name: name, columns: ["region_id"], referencedTable: "regions",
                referencedColumns: ["id"], referencedSchema: "shop", onDelete: .cascade, onUpdate: .noAction
            )
        }
        let check = { (expression: String) in
            EditableCheckConstraintDefinition(
                id: UUID(), name: "positive_total", expression: expression, columns: ["total"], isValidated: true
            )
        }
        let makers: [(String, () -> SchemaChange)] = [
            ("addColumn", { .addColumn(self.column("total")) }),
            ("modifyColumn", { .modifyColumn(old: self.column("total"), new: self.column("total", "bigint")) }),
            ("deleteColumn", { .deleteColumn(self.column("total")) }),
            ("addIndex", { .addIndex(index("orders_total_idx")) }),
            ("modifyIndex", { .modifyIndex(old: index("orders_total_idx"), new: index("orders_sum_idx")) }),
            ("deleteIndex", { .deleteIndex(index("orders_total_idx")) }),
            ("addForeignKey", { .addForeignKey(foreignKey("orders_region_fkey")) }),
            ("modifyForeignKey", {
                .modifyForeignKey(old: foreignKey("orders_region_fkey"), new: foreignKey("orders_area_fkey"))
            }),
            ("deleteForeignKey", { .deleteForeignKey(foreignKey("orders_region_fkey")) }),
            ("addCheckConstraint", { .addCheckConstraint(check("total > 0")) }),
            ("modifyCheckConstraint", { .modifyCheckConstraint(old: check("total > 0"), new: check("total >= 0")) }),
            ("deleteCheckConstraint", { .deleteCheckConstraint(check("total > 0")) }),
            ("modifyPrimaryKey", { .modifyPrimaryKey(old: ["id"], new: ["id", "region_id"]) })
        ]

        for (label, make) in makers {
            let expected = inputs([table(changes: [make()])], action: .alter)
            let actual = inputs([table(changes: [make()])], action: .alter)
            #expect(StructureChangeGuard.refusal(expected: expected, actual: actual) == nil, Comment(rawValue: label))
        }
    }

    // MARK: - Scope of the check

    @Test
    func anObjectTheUserSkippedIsNotChecked() {
        let expected = StructureChangeGuard.inputs(
            for: [table(changes: [.addColumn(column("total"))])],
            actions: { _ in .skip },
            sourceSnapshots: [:]
        )

        #expect(expected.isEmpty)
        #expect(StructureChangeGuard.refusal(expected: expected, actual: [:]) == nil)
    }

    /// Another table moving in the same schema is somebody else's work. Refusing on it would make a
    /// busy database impossible to sync.
    @Test
    func anObjectOutsideTheSelectionDoesNotRefuse() {
        let selected = table(changes: [.addColumn(column("total"))])
        let other = CompareObjectResult(
            identity: CompareObjectIdentity(kind: .table, schema: "shop", name: "customers"),
            status: .differs,
            changes: [.addColumn(column("email"))]
        )
        var actual = inputs([selected], action: .alter)
        actual.merge(inputs([other], action: .alter)) { first, _ in first }

        #expect(StructureChangeGuard.refusal(expected: inputs([selected], action: .alter), actual: actual) == nil)
    }

    @Test
    func theRefusalNamesTheObject() {
        let refusal = StructureChangeGuard.refusal(
            expected: inputs([table(changes: [.addColumn(column("total"))])], action: .alter),
            actual: [:]
        )

        let message = try? #require(refusal?.errorDescription)
        #expect(message?.contains("shop.orders") ?? false,
            "the message must name what changed, got \(message ?? "nil")")
    }

    @Test
    func anObjectThatCouldNotBeReadAgainIsRefusedWithItsReason() throws {
        let result = view(definition: ["CREATE VIEW recent_orders AS SELECT 1"])
        let reason = SourceDefinitionDefect.unreadable("SHOW VIEW command denied").reason(on: .source)

        let refusal = StructureChangeGuard.refusal(
            expected: inputs([result], action: .create),
            actual: [:],
            unreadable: [result.id: reason]
        )

        let message = try #require(refusal?.errorDescription)
        #expect(message.contains("shop.recent_orders"), Comment(rawValue: message))
        #expect(message.contains(reason), Comment(rawValue: message))
        #expect(!message.contains("changed after it was compared"), Comment(rawValue: message))
    }

    @Test
    func anUnreadableObjectOutsideTheSelectionDoesNotRefuse() {
        let selected = view(definition: ["CREATE VIEW recent_orders AS SELECT 1"])
        let expected = inputs([selected], action: .create)

        #expect(StructureChangeGuard.refusal(
                expected: expected,
                actual: expected,
                unreadable: ["view|shop|other|": "denied"]
            ) == nil)
    }
}
