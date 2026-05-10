//
//  IndexDefinitionTests.swift
//  TablePro
//
//  Tests for EditableIndexDefinition
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("Editable Index Definition")
struct IndexDefinitionTests {
    // MARK: - placeholder Tests

    @Test("placeholder creates index with empty fields")
    func placeholderHasEmptyFields() {
        let placeholder = EditableIndexDefinition.placeholder()
        #expect(placeholder.name == "")
        #expect(placeholder.columns.isEmpty == true)
        #expect(placeholder.type == .btree)
        #expect(placeholder.isUnique == false)
        #expect(placeholder.isPrimary == false)
        #expect(placeholder.comment == nil)
    }

    @Test("placeholder isValid returns false")
    func placeholderIsNotValid() {
        let placeholder = EditableIndexDefinition.placeholder()
        #expect(placeholder.isValid == false)
    }

    // MARK: - isValid Tests

    @Test("isValid returns true for valid index")
    func validIndexIsValid() {
        let index = EditableIndexDefinition(
            id: UUID(),
            name: "idx_email",
            columns: ["email"],
            type: .btree,
            isUnique: true,
            isPrimary: false,
            comment: nil
        )
        #expect(index.isValid == true)
    }

    @Test("isValid returns false when name is whitespace only")
    func invalidWhenNameIsWhitespace() {
        let index = EditableIndexDefinition(
            id: UUID(),
            name: "   ",
            columns: ["email"],
            type: .btree,
            isUnique: false,
            isPrimary: false,
            comment: nil
        )
        #expect(index.isValid == false)
    }

    @Test("isValid returns false when columns is empty")
    func invalidWhenColumnsEmpty() {
        let index = EditableIndexDefinition(
            id: UUID(),
            name: "idx_test",
            columns: [],
            type: .btree,
            isUnique: false,
            isPrimary: false,
            comment: nil
        )
        #expect(index.isValid == false)
    }

    // MARK: - Round-trip Conversion Tests

    @Test("from(IndexInfo) creates EditableIndexDefinition with matching fields")
    func fromIndexInfoRoundTrip() {
        let indexInfo = IndexInfo(
            name: "idx_users_email",
            columns: ["email", "status"],
            isUnique: true,
            isPrimary: false,
            type: "BTREE"
        )

        let editable = EditableIndexDefinition.from(indexInfo)

        #expect(editable.name == "idx_users_email")
        #expect(editable.columns == ["email", "status"])
        #expect(editable.isUnique == true)
        #expect(editable.isPrimary == false)
        #expect(editable.type == .btree)
    }

    @Test("toIndexInfo creates IndexInfo with matching fields")
    func toIndexInfoRoundTrip() {
        let editable = EditableIndexDefinition(
            id: UUID(),
            name: "idx_posts_created_at",
            columns: ["created_at"],
            type: .hash,
            isUnique: false,
            isPrimary: false,
            comment: "Index on creation date"
        )

        let indexInfo = editable.toIndexInfo()

        #expect(indexInfo.name == "idx_posts_created_at")
        #expect(indexInfo.columns == ["created_at"])
        #expect(indexInfo.isUnique == false)
        #expect(indexInfo.isPrimary == false)
        #expect(indexInfo.type == "HASH")
    }

    @Test("type mapping handles BTREE correctly")
    func typeMappingBtree() {
        let indexInfo = IndexInfo(
            name: "idx_test",
            columns: ["id"],
            isUnique: false,
            isPrimary: false,
            type: "btree"
        )

        let editable = EditableIndexDefinition.from(indexInfo)
        #expect(editable.type == .btree)

        let convertedBack = editable.toIndexInfo()
        #expect(convertedBack.type == "BTREE")
    }

    @Test("type mapping handles HASH correctly")
    func typeMappingHash() {
        let indexInfo = IndexInfo(
            name: "idx_test",
            columns: ["id"],
            isUnique: false,
            isPrimary: false,
            type: "hash"
        )

        let editable = EditableIndexDefinition.from(indexInfo)
        #expect(editable.type == .hash)

        let convertedBack = editable.toIndexInfo()
        #expect(convertedBack.type == "HASH")
    }

    @Test("type mapping handles FULLTEXT correctly")
    func typeMappingFulltext() {
        let indexInfo = IndexInfo(
            name: "idx_test",
            columns: ["content"],
            isUnique: false,
            isPrimary: false,
            type: "fulltext"
        )

        let editable = EditableIndexDefinition.from(indexInfo)
        #expect(editable.type == .fulltext)

        let convertedBack = editable.toIndexInfo()
        #expect(convertedBack.type == "FULLTEXT")
    }

    @Test("type mapping defaults to BTREE for unknown type")
    func typeMappingUnknownDefaultsToBtree() {
        let indexInfo = IndexInfo(
            name: "idx_test",
            columns: ["id"],
            isUnique: false,
            isPrimary: false,
            type: "UNKNOWN"
        )

        let editable = EditableIndexDefinition.from(indexInfo)
        #expect(editable.type == .btree)
    }

    @Test("full round-trip preserves data integrity")
    func fullRoundTripPreservesData() {
        let originalInfo = IndexInfo(
            name: "PRIMARY",
            columns: ["id", "tenant_id"],
            isUnique: true,
            isPrimary: true,
            type: "BTREE"
        )

        let editable = EditableIndexDefinition.from(originalInfo)
        let convertedBack = editable.toIndexInfo()

        #expect(convertedBack.name == originalInfo.name)
        #expect(convertedBack.columns == originalInfo.columns)
        #expect(convertedBack.isUnique == originalInfo.isUnique)
        #expect(convertedBack.isPrimary == originalInfo.isPrimary)
        #expect(convertedBack.type == originalInfo.type)
    }
}
