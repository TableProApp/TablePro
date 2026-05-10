//
//  ForeignKeyDefinitionTests.swift
//  TablePro
//
//  Tests for EditableForeignKeyDefinition
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("Editable Foreign Key Definition")
struct ForeignKeyDefinitionTests {
    // MARK: - placeholder Tests

    @Test("placeholder creates foreign key with empty fields")
    func placeholderHasEmptyFields() {
        let placeholder = EditableForeignKeyDefinition.placeholder()
        #expect(placeholder.name == "")
        #expect(placeholder.columns.isEmpty == true)
        #expect(placeholder.referencedTable == "")
        #expect(placeholder.referencedColumns.isEmpty == true)
        #expect(placeholder.onDelete == .noAction)
        #expect(placeholder.onUpdate == .noAction)
    }

    @Test("placeholder isValid returns false")
    func placeholderIsNotValid() {
        let placeholder = EditableForeignKeyDefinition.placeholder()
        #expect(placeholder.isValid == false)
    }

    // MARK: - isValid Tests

    @Test("isValid returns true for valid foreign key")
    func validForeignKeyIsValid() {
        let fk = EditableForeignKeyDefinition(
            id: UUID(),
            name: "fk_user_id",
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: ["id"],
            onDelete: .cascade,
            onUpdate: .noAction
        )
        #expect(fk.isValid == true)
    }

    @Test("isValid returns false when name is whitespace only")
    func invalidWhenNameIsWhitespace() {
        let fk = EditableForeignKeyDefinition(
            id: UUID(),
            name: "   ",
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: ["id"],
            onDelete: .noAction,
            onUpdate: .noAction
        )
        #expect(fk.isValid == false)
    }

    @Test("isValid returns false when columns is empty")
    func invalidWhenColumnsEmpty() {
        let fk = EditableForeignKeyDefinition(
            id: UUID(),
            name: "fk_test",
            columns: [],
            referencedTable: "users",
            referencedColumns: ["id"],
            onDelete: .noAction,
            onUpdate: .noAction
        )
        #expect(fk.isValid == false)
    }

    @Test("isValid returns false when referencedTable is whitespace only")
    func invalidWhenReferencedTableIsWhitespace() {
        let fk = EditableForeignKeyDefinition(
            id: UUID(),
            name: "fk_test",
            columns: ["user_id"],
            referencedTable: "   ",
            referencedColumns: ["id"],
            onDelete: .noAction,
            onUpdate: .noAction
        )
        #expect(fk.isValid == false)
    }

    @Test("isValid returns false when referencedColumns is empty")
    func invalidWhenReferencedColumnsEmpty() {
        let fk = EditableForeignKeyDefinition(
            id: UUID(),
            name: "fk_test",
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: [],
            onDelete: .noAction,
            onUpdate: .noAction
        )
        #expect(fk.isValid == false)
    }

    // MARK: - Round-trip Conversion Tests

    @Test("from(ForeignKeyInfo) creates EditableForeignKeyDefinition with matching fields")
    func fromForeignKeyInfoRoundTrip() {
        let fkInfo = ForeignKeyInfo(
            name: "fk_posts_user_id",
            column: "user_id",
            referencedTable: "users",
            referencedColumn: "id",
            onDelete: "CASCADE",
            onUpdate: "NO ACTION"
        )

        let editable = EditableForeignKeyDefinition.from(fkInfo)

        #expect(editable.name == "fk_posts_user_id")
        #expect(editable.columns == ["user_id"])
        #expect(editable.referencedTable == "users")
        #expect(editable.referencedColumns == ["id"])
        #expect(editable.onDelete == .cascade)
        #expect(editable.onUpdate == .noAction)
    }

    @Test("toForeignKeyInfo creates ForeignKeyInfo with matching fields")
    func toForeignKeyInfoRoundTrip() {
        let editable = EditableForeignKeyDefinition(
            id: UUID(),
            name: "fk_comments_post_id",
            columns: ["post_id"],
            referencedTable: "posts",
            referencedColumns: ["id"],
            onDelete: .setNull,
            onUpdate: .cascade
        )

        let fkInfo = editable.toForeignKeyInfo()

        #expect(fkInfo != nil)
        #expect(fkInfo?.name == "fk_comments_post_id")
        #expect(fkInfo?.column == "post_id")
        #expect(fkInfo?.referencedTable == "posts")
        #expect(fkInfo?.referencedColumn == "id")
        #expect(fkInfo?.onDelete == "SET NULL")
        #expect(fkInfo?.onUpdate == "CASCADE")
    }

    @Test("toForeignKeyInfo returns nil when columns is empty")
    func toForeignKeyInfoNilWithEmptyColumns() {
        let editable = EditableForeignKeyDefinition(
            id: UUID(),
            name: "fk_test",
            columns: [],
            referencedTable: "users",
            referencedColumns: ["id"],
            onDelete: .noAction,
            onUpdate: .noAction
        )

        let fkInfo = editable.toForeignKeyInfo()
        #expect(fkInfo == nil)
    }

    @Test("toForeignKeyInfo returns nil when referencedColumns is empty")
    func toForeignKeyInfoNilWithEmptyReferencedColumns() {
        let editable = EditableForeignKeyDefinition(
            id: UUID(),
            name: "fk_test",
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: [],
            onDelete: .noAction,
            onUpdate: .noAction
        )

        let fkInfo = editable.toForeignKeyInfo()
        #expect(fkInfo == nil)
    }

    @Test("full round-trip preserves data integrity")
    func fullRoundTripPreservesData() {
        let originalInfo = ForeignKeyInfo(
            name: "fk_orders_customer_id",
            column: "customer_id",
            referencedTable: "customers",
            referencedColumn: "id",
            onDelete: "RESTRICT",
            onUpdate: "CASCADE"
        )

        let editable = EditableForeignKeyDefinition.from(originalInfo)
        let convertedBack = editable.toForeignKeyInfo()

        #expect(convertedBack != nil)
        #expect(convertedBack?.name == originalInfo.name)
        #expect(convertedBack?.column == originalInfo.column)
        #expect(convertedBack?.referencedTable == originalInfo.referencedTable)
        #expect(convertedBack?.referencedColumn == originalInfo.referencedColumn)
        #expect(convertedBack?.onDelete == originalInfo.onDelete)
        #expect(convertedBack?.onUpdate == originalInfo.onUpdate)
    }
}
