//
//  TableInfoTests.swift
//  TableProTests
//
//  Tests for TableInfo struct identity, equality, and hashing behavior.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("TableInfo")
struct TableInfoTests {
    // MARK: - Identifiable

    @Test("id returns name_TABLE for a table")
    func testIdForTable() {
        let info = TableInfo(name: "users", type: .table, rowCount: 100)
        #expect(info.id == "users_TABLE")
    }

    @Test("id returns name_VIEW for a view")
    func testIdForView() {
        let info = TableInfo(name: "my_view", type: .view, rowCount: nil)
        #expect(info.id == "my_view_VIEW")
    }

    @Test("id returns name_SYSTEM TABLE for a system table")
    func testIdForSystemTable() {
        let info = TableInfo(name: "sys", type: .systemTable, rowCount: nil)
        #expect(info.id == "sys_SYSTEM TABLE")
    }

    @Test("Same name and type produce same id")
    func testSameNameTypeSameId() {
        let a = TableInfo(name: "orders", type: .table, rowCount: 10)
        let b = TableInfo(name: "orders", type: .table, rowCount: 999)
        #expect(a.id == b.id)
    }

    @Test("Different types produce different id")
    func testDifferentTypesDifferentId() {
        let table = TableInfo(name: "items", type: .table, rowCount: nil)
        let view = TableInfo(name: "items", type: .view, rowCount: nil)
        #expect(table.id != view.id)
    }

    @Test("Schema-qualified id includes the schema")
    func testSchemaQualifiedId() {
        let info = TableInfo(name: "events", type: .table, rowCount: nil, schema: "analytics")
        #expect(info.id == "analytics.events_TABLE")
    }

    @Test("Same table name in different schemas has distinct id, equality, and hash")
    func testCrossSchemaDistinctIdentity() {
        let a = TableInfo(name: "orders", type: .table, rowCount: nil, schema: "dataset_a")
        let b = TableInfo(name: "orders", type: .table, rowCount: nil, schema: "dataset_b")
        #expect(a.id != b.id)
        #expect(a != b)
        let set: Set<TableInfo> = [a, b]
        #expect(set.count == 2)
    }

    // MARK: - Equatable

    @Test("Same name and type are equal even with different rowCount")
    func testEqualSameNameType() {
        let a = TableInfo(name: "users", type: .table, rowCount: 100)
        let b = TableInfo(name: "users", type: .table, rowCount: 0)
        #expect(a == b)
    }

    @Test("Different names are not equal")
    func testNotEqualDifferentNames() {
        let a = TableInfo(name: "users", type: .table, rowCount: nil)
        let b = TableInfo(name: "orders", type: .table, rowCount: nil)
        #expect(a != b)
    }

    @Test("Different types are not equal with same name")
    func testNotEqualDifferentTypes() {
        let table = TableInfo(name: "items", type: .table, rowCount: nil)
        let view = TableInfo(name: "items", type: .view, rowCount: nil)
        #expect(table != view)
    }

    @Test("Separately created instances for same table are equal")
    func testSeparateInstancesEqual() {
        let a = TableInfo(name: "products", type: .table, rowCount: 50)
        let b = TableInfo(name: "products", type: .table, rowCount: 50)
        #expect(a == b)
    }

    // MARK: - Hashable

    @Test("Same name and type produce same hash")
    func testSameHash() {
        let a = TableInfo(name: "users", type: .table, rowCount: 10)
        let b = TableInfo(name: "users", type: .table, rowCount: 999)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Can be stored in a Set and looked up")
    func testSetLookup() {
        let info = TableInfo(name: "users", type: .table, rowCount: 100)
        let set: Set<TableInfo> = [info]
        #expect(set.contains(info))
    }

    @Test("Set contains works across separate instances")
    func testSetContainsSeparateInstances() {
        let a = TableInfo(name: "users", type: .table, rowCount: 100)
        let set: Set<TableInfo> = [a]

        let b = TableInfo(name: "users", type: .table, rowCount: 200)
        #expect(set.contains(b))
    }

    @Test("Inserting duplicate does not increase set count")
    func testSetDeduplication() {
        let a = TableInfo(name: "orders", type: .view, rowCount: nil)
        let b = TableInfo(name: "orders", type: .view, rowCount: 42)
        var set: Set<TableInfo> = [a]
        set.insert(b)
        #expect(set.count == 1)
    }

    // MARK: - Set behavior (selection use case)

    @Test("Set correctly deduplicates by name and type")
    func testSetDeduplicatesByNameAndType() {
        let items: [TableInfo] = [
            TableInfo(name: "users", type: .table, rowCount: 10),
            TableInfo(name: "users", type: .table, rowCount: 20),
            TableInfo(name: "orders", type: .table, rowCount: 5),
        ]
        let set = Set(items)
        #expect(set.count == 2)
    }

    @Test("Set contains works for separately created instances")
    func testSetContainsForSeparateInstances() {
        let selected: Set<TableInfo> = [
            TableInfo(name: "users", type: .table, rowCount: nil),
            TableInfo(name: "orders", type: .view, rowCount: nil),
        ]

        let lookup = TableInfo(name: "users", type: .table, rowCount: 999)
        #expect(selected.contains(lookup))
    }

    // MARK: - Comment does not affect identity

    @Test("Comment does not affect equality")
    func testCommentDoesNotAffectEquality() {
        let a = TableInfo(name: "users", type: .table, rowCount: nil, comment: "Account records")
        let b = TableInfo(name: "users", type: .table, rowCount: nil, comment: nil)
        #expect(a == b)
    }

    @Test("Comment does not affect hash")
    func testCommentDoesNotAffectHash() {
        let a = TableInfo(name: "users", type: .table, rowCount: nil, comment: "Account records")
        let b = TableInfo(name: "users", type: .table, rowCount: nil, comment: "Something else")
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Set deduplication ignores comment")
    func testSetDeduplicationIgnoresComment() {
        let a = TableInfo(name: "orders", type: .table, rowCount: nil, comment: "First")
        let b = TableInfo(name: "orders", type: .table, rowCount: nil, comment: "Second")
        var set: Set<TableInfo> = [a]
        set.insert(b)
        #expect(set.count == 1)
    }

    @Test("Subtracting sets works correctly")
    func testSetSubtraction() {
        let all: Set<TableInfo> = [
            TableInfo(name: "users", type: .table, rowCount: nil),
            TableInfo(name: "orders", type: .table, rowCount: nil),
            TableInfo(name: "products", type: .view, rowCount: nil),
        ]
        let toRemove: Set<TableInfo> = [
            TableInfo(name: "orders", type: .table, rowCount: 42),
        ]

        let result = all.subtracting(toRemove)
        #expect(result.count == 2)
        #expect(!result.contains(TableInfo(name: "orders", type: .table, rowCount: nil)))
        #expect(result.contains(TableInfo(name: "users", type: .table, rowCount: nil)))
        #expect(result.contains(TableInfo(name: "products", type: .view, rowCount: nil)))
    }

    // MARK: - Row Editing

    @Test("A view does not allow row editing")
    func viewDisallowsRowEditing() {
        #expect(!TableInfo.TableType.view.allowsRowEditing)
    }

    @Test("An external table does not allow row editing")
    func externalTableDisallowsRowEditing() {
        #expect(!TableInfo.TableType.externalTable.allowsRowEditing)
    }

    @Test("Local relations still allow row editing")
    func localRelationsAllowRowEditing() {
        #expect(TableInfo.TableType.table.allowsRowEditing)
        #expect(TableInfo.TableType.materializedView.allowsRowEditing)
        #expect(TableInfo.TableType.foreignTable.allowsRowEditing)
        #expect(TableInfo.TableType.systemTable.allowsRowEditing)
        #expect(TableInfo.TableType.partitionedTable.allowsRowEditing)
    }

    @Test("External table round-trips through its raw value")
    func externalTableRawValue() {
        #expect(TableInfo.TableType.externalTable.rawValue == "EXTERNAL TABLE")
        #expect(TableInfo.TableType(rawValue: "EXTERNAL TABLE") == .externalTable)
    }

    /// Measured on MariaDB 11.4.13: a sequence takes an INSERT and refuses UPDATE, DELETE and
    /// TRUNCATE with ERROR 1031, so an editable grid over one offers two writes the server
    /// always refuses.
    @Test("A sequence does not allow row editing")
    func sequenceDisallowsRowEditing() {
        #expect(!TableInfo.TableType.sequence.allowsRowEditing)
        #expect(!TableInfo.TableType.sequence.isForeignKeyTarget)
    }

    @Test("Sequence round-trips through its raw value")
    func sequenceRawValue() {
        #expect(TableInfo.TableType.sequence.rawValue == "SEQUENCE")
        #expect(TableInfo.TableType(rawValue: "SEQUENCE") == .sequence)
    }

    // MARK: - Picker eligibility

    /// `mariadb-dump 12.3.3` writes `CREATE SEQUENCE` plus `DO SETVAL` for a sequence and
    /// `CREATE TABLE ... PARTITION BY` with every row for a partitioned parent, so all three are
    /// worth listing in the Backup Dump object tree.
    @Test("Tables, partitioned tables and sequences are backup-selectable")
    func backupSelectableKinds() {
        for type in [TableInfo.TableType.table, .partitionedTable, .sequence] {
            #expect(type.isBackupSelectable, "\(type.rawValue) should be backup-selectable")
        }
        for type in [TableInfo.TableType.view, .materializedView, .foreignTable, .systemTable, .externalTable] {
            #expect(!type.isBackupSelectable, "\(type.rawValue) should not be backup-selectable")
        }
    }

    /// Narrower than the backup list. MariaDB stores exactly one row in a sequence, so importing
    /// rows into one is not a thing the picker should offer.
    @Test("Only a table and a partitioned table accept imported rows")
    func importTargetKinds() {
        for type in [TableInfo.TableType.table, .partitionedTable] {
            #expect(type.acceptsImportedRows, "\(type.rawValue) should accept imported rows")
        }
        for type in [
            TableInfo.TableType.view, .materializedView, .foreignTable, .systemTable, .externalTable, .sequence,
        ] {
            #expect(!type.acceptsImportedRows, "\(type.rawValue) should not accept imported rows")
        }
    }

    /// A trait, not part of identity: the same table with versioning turned on is the same table,
    /// which is what keeps a refresh from replacing every row in the sidebar.
    @Test("System versioning stays out of equality and hashing")
    func systemVersioningIsNotIdentity() {
        let plain = TableInfo(name: "audit", type: .table, rowCount: nil, schema: "app")
        let versioned = TableInfo(
            name: "audit", type: .table, rowCount: nil, schema: "app", isSystemVersioned: true
        )

        #expect(plain == versioned)
        #expect(plain.hashValue == versioned.hashValue)
        #expect(versioned.isSystemVersioned)
        #expect(!plain.isSystemVersioned)
    }
}
