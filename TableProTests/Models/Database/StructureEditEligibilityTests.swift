//
//  StructureEditEligibilityTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

/// Every cell of the PostgreSQL matrix below was measured against a live PostgreSQL 17.11 server,
/// one statement per cell, rather than read out of the documentation. The pair that matters most is
/// `SET DEFAULT` and `CREATE INDEX`: a view takes the first and refuses the second, a materialized
/// view does the opposite, and that alone rules out sharing one row between them or collapsing the
/// object's kind to a single read-only Bool. (#2726)
@Suite("Structure Edit Eligibility")
struct StructureEditEligibilityTests {
    private func allows(
        _ operation: StructureEditOperation,
        _ kind: TableInfo.TableType,
        _ matrix: StructureObjectEditMatrix
    ) -> Bool {
        StructureEditEligibility.allows(operation, on: kind, matrix: matrix)
    }

    // MARK: - The uncurated default

    @Test("An uncurated engine offers every edit on a table and a partitioned table")
    func tablesOnlyAllowsEverythingOnTables() {
        for kind in [TableInfo.TableType.table, .partitionedTable] {
            for operation in StructureEditOperation.allCases {
                #expect(allows(operation, kind, .tablesOnly), "\(kind.rawValue) refused \(operation)")
            }
        }
    }

    @Test("An uncurated engine offers nothing on anything that is not a table")
    func tablesOnlyRefusesEveryOtherKind() {
        let kinds: [TableInfo.TableType] = [.view, .materializedView, .foreignTable, .systemTable, .externalTable]
        for kind in kinds {
            #expect(!StructureEditEligibility.allowsAnyEdit(on: kind, matrix: .tablesOnly), "\(kind.rawValue)")
            for operation in StructureEditOperation.allCases {
                #expect(!allows(operation, kind, .tablesOnly), "\(kind.rawValue) offered \(operation)")
            }
        }
    }

    // MARK: - PostgreSQL, as measured

    @Test("A PostgreSQL view takes exactly the four edits the server accepts")
    func postgresViewMatchesTheServer() {
        let accepted: Set<StructureEditOperation> = [.renameColumn, .setDefault, .dropDefault, .commentOnColumn]
        for operation in StructureEditOperation.allCases {
            #expect(
                allows(operation, .view, .postgreSQL) == accepted.contains(operation),
                "view disagreed about \(operation)"
            )
        }
    }

    @Test("A PostgreSQL materialized view takes an index and refuses a default")
    func postgresMaterializedViewMatchesTheServer() {
        let accepted: Set<StructureEditOperation> = [.renameColumn, .commentOnColumn, .addIndex, .dropIndex]
        for operation in StructureEditOperation.allCases {
            #expect(
                allows(operation, .materializedView, .postgreSQL) == accepted.contains(operation),
                "materialized view disagreed about \(operation)"
            )
        }
    }

    /// The one cell that proves a view and a materialized view cannot share a matrix row. Measured:
    /// `ALTER MATERIALIZED VIEW … SET DEFAULT` answers "ALTER action ALTER COLUMN ... SET DEFAULT
    /// cannot be performed on relation mv", while the same statement on a view succeeds.
    @Test("A view and a materialized view disagree about SET DEFAULT and CREATE INDEX")
    func viewAndMaterializedViewDiffer() {
        #expect(allows(.setDefault, .view, .postgreSQL))
        #expect(!allows(.setDefault, .materializedView, .postgreSQL))
        #expect(!allows(.addIndex, .view, .postgreSQL))
        #expect(allows(.addIndex, .materializedView, .postgreSQL))
    }

    @Test("A PostgreSQL foreign table takes every column change but no index and no key")
    func postgresForeignTableMatchesTheServer() {
        let accepted: Set<StructureEditOperation> = [
            .addColumn, .dropColumn, .renameColumn, .setNotNull, .dropNotNull, .setDefault,
            .dropDefault, .changeColumnType, .addCheckConstraint, .dropCheckConstraint, .commentOnColumn
        ]
        for operation in StructureEditOperation.allCases {
            #expect(
                allows(operation, .foreignTable, .postgreSQL) == accepted.contains(operation),
                "foreign table disagreed about \(operation)"
            )
        }
    }

    @Test("A PostgreSQL system table and external table take nothing")
    func postgresReadOnlyKindsTakeNothing() {
        for kind in [TableInfo.TableType.systemTable, .externalTable] {
            #expect(!StructureEditEligibility.allowsAnyEdit(on: kind, matrix: .postgreSQL), "\(kind.rawValue)")
        }
    }

    @Test("A PostgreSQL table and partitioned table still take every edit")
    func postgresTablesTakeEverything() {
        for kind in [TableInfo.TableType.table, .partitionedTable] {
            for operation in StructureEditOperation.allCases {
                #expect(allows(operation, kind, .postgreSQL), "\(kind.rawValue) refused \(operation)")
            }
        }
    }

    // MARK: - Per-field locking

    @Test("A view keeps Name, Default and Comment editable and locks the rest")
    func viewEditableFields() {
        let fields = StructureEditEligibility.editableFields(on: .view, matrix: .postgreSQL)
        #expect(fields == [.name, .defaultValue, .comment])
    }

    @Test("A materialized view keeps only Name and Comment editable")
    func materializedViewEditableFields() {
        let fields = StructureEditEligibility.editableFields(on: .materializedView, matrix: .postgreSQL)
        #expect(fields == [.name, .comment])
    }

    /// Primary Key, Auto Inc, On Update, Charset, Collation and Generated are all expressed by
    /// rewriting the column definition, so they travel together behind `redefineColumn` rather than
    /// each being gated through a proxy that means something else.
    @Test("A foreign table locks the fields that need a column rewrite and opens the rest")
    func foreignTableEditableFields() {
        let fields = StructureEditEligibility.editableFields(on: .foreignTable, matrix: .postgreSQL)
        #expect(fields == [.name, .type, .nullable, .defaultValue, .comment])
        #expect(!fields.contains(.primaryKey))
        #expect(!fields.contains(.autoIncrement))
    }

    @Test("A system table locks every field")
    func systemTableLocksEverything() {
        #expect(StructureEditEligibility.editableFields(on: .systemTable, matrix: .postgreSQL).isEmpty)
        #expect(!StructureEditEligibility.allowsAnyEdit(on: .systemTable, matrix: .postgreSQL))
    }

    @Test("A table opens every field of the Columns grid")
    func tableOpensEveryField() {
        let fields = StructureEditEligibility.editableFields(on: .table, matrix: .postgreSQL)
        #expect(fields == Set(StructureColumnField.allCases))
    }

    // MARK: - Reasons

    @Test("Every refusal carries a sentence, for every kind and every operation")
    func everyRefusalExplainsItself() {
        for kind in TableInfo.TableType.allCases {
            for operation in StructureEditOperation.allCases {
                let availability = StructureEditEligibility.resolve(
                    operation,
                    on: kind,
                    matrix: .postgreSQL,
                    engineAllows: true,
                    engineName: "PostgreSQL",
                    canEditSchema: true
                )
                guard !availability.isAvailable else { continue }
                #expect(
                    availability.unavailableReason?.isEmpty == false,
                    "\(kind.rawValue) refused \(operation) with no reason"
                )
            }
        }
    }

    /// Each refusal names the kind the user is looking at, which is the half the old `isTable` Bool
    /// could not supply: it made every non-table say "A view ...".
    @Test("A refusal names the object's own kind")
    func refusalNamesTheKind() {
        let matview = StructureEditEligibility.refusalReason(
            for: .setDefault, on: .materializedView, matrix: .postgreSQL
        )
        #expect(matview?.contains("materialized view") == true)

        let foreign = StructureEditEligibility.refusalReason(
            for: .addIndex, on: .foreignTable, matrix: .postgreSQL
        )
        #expect(foreign?.contains("foreign table") == true)
    }

    @Test("An accepted operation has no reason to give")
    func acceptedOperationHasNoReason() {
        #expect(StructureEditEligibility.refusalReason(for: .addIndex, on: .materializedView, matrix: .postgreSQL) == nil)
        #expect(StructureEditEligibility.refusalReason(for: .addColumn, on: .table, matrix: .tablesOnly) == nil)
    }

    // MARK: - Ordering

    @Test("An engine that cannot edit structure at all says that first, even on a table")
    func readOnlyEngineOutranksTheKind() {
        let availability = StructureEditEligibility.resolve(
            .addColumn,
            on: .table,
            matrix: .postgreSQL,
            engineAllows: true,
            engineName: "Engine",
            canEditSchema: false
        )
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason?.contains("Engine") == true)
    }

    /// The kind allowing an edit is necessary, not sufficient. An engine with no `CREATE INDEX`
    /// refuses it on a plain table too, and that refusal has to survive the new gate.
    @Test("An engine flag still vetoes an operation the kind allows")
    func engineFlagStillVetoes() {
        let availability = StructureEditEligibility.resolve(
            .addIndex,
            on: .table,
            matrix: .postgreSQL,
            engineAllows: false,
            engineName: "Engine",
            canEditSchema: true
        )
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason?.contains("Engine") == true)
        #expect(availability.unavailableReason?.contains("indexes") == true)
    }

    /// An engine refusal worded once would put "cannot edit a table's structure" under a dimmed
    /// **Add Index**, which tells the reader nothing they could act on.
    @Test("An engine refusal names what it cannot do, not just that it cannot")
    func engineRefusalNamesTheSubject() {
        let subjects: [(StructureEditOperation, String)] = [
            (.addColumn, "columns"),
            (.reorderColumns, "order"),
            (.addIndex, "indexes"),
            (.addCheckConstraint, "constraints")
        ]
        for (operation, expected) in subjects {
            let availability = StructureEditEligibility.resolve(
                operation,
                on: .table,
                matrix: .postgreSQL,
                engineAllows: false,
                engineName: "Engine",
                canEditSchema: true
            )
            #expect(availability.unavailableReason?.contains(expected) == true, "\(operation)")
        }
    }

    @Test("The kind outranks the engine flag, so the reason names the object rather than the engine")
    func kindOutranksTheEngineFlag() {
        let availability = StructureEditEligibility.resolve(
            .addColumn,
            on: .view,
            matrix: .postgreSQL,
            engineAllows: true,
            engineName: "PostgreSQL",
            canEditSchema: true
        )
        #expect(availability.unavailableReason?.contains("view") == true)
    }
}
