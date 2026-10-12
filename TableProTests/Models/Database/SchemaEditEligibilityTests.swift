//
//  SchemaEditEligibilityTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct SchemaEditEligibilityTests {
    private func context(
        supportsCreateSchema: Bool = true,
        supportsSchemaOwner: Bool = true,
        supportsSchemaPrivileges: Bool = true,
        supportsRenameSchema: Bool = true,
        isReadOnly: Bool = false
    ) -> SchemaEditEligibility.Context {
        SchemaEditEligibility.Context(
            supportsCreateSchema: supportsCreateSchema,
            supportsSchemaOwner: supportsSchemaOwner,
            supportsSchemaPrivileges: supportsSchemaPrivileges,
            supportsRenameSchema: supportsRenameSchema,
            isReadOnly: isReadOnly
        )
    }

    private let schema = DatabaseContainerRef.schema(database: "sales", schema: "app")

    @Test("An engine that makes schemas offers Create")
    func createOffered() {
        #expect(SchemaEditEligibility.canCreate(context: context()))
    }

    @Test("An engine with no CREATE SCHEMA never offers it")
    func createRefusedWithoutCapability() {
        #expect(!SchemaEditEligibility.canCreate(context: context(supportsCreateSchema: false)))
    }

    @Test("A read-only connection offers neither Create nor Edit")
    func readOnlyRefusesBoth() {
        let readOnly = context(isReadOnly: true)
        #expect(!SchemaEditEligibility.canCreate(context: readOnly))
        #expect(SchemaEditEligibility.editable([schema], context: readOnly) == nil)
    }

    @Test("A schema row offers Edit")
    func editOffered() {
        #expect(SchemaEditEligibility.editable([schema], context: context()) == schema)
    }

    @Test("A system schema is never edited")
    func systemSchemaRefused() {
        let system = DatabaseContainerRef.schema(database: "sales", schema: "pg_catalog", isSystem: true)
        #expect(SchemaEditEligibility.editable([system], context: context()) == nil)
    }

    @Test("A database row is not a schema, so Edit stays off it")
    func databaseRowRefused() {
        let database = DatabaseContainerRef.database("sales")
        #expect(SchemaEditEligibility.editable([database], context: context()) == nil)
    }

    @Test("A multi-row selection offers no Edit, because the sheet edits one schema")
    func multiSelectionRefused() {
        let other = DatabaseContainerRef.schema(database: "sales", schema: "reporting")
        #expect(SchemaEditEligibility.editable([schema, other], context: context()) == nil)
    }

    @Test("An empty selection offers no Edit")
    func emptySelectionRefused() {
        #expect(SchemaEditEligibility.editable([], context: context()) == nil)
    }

    /// An engine that makes schemas but exposes no owner, no privileges and no rename has nothing
    /// to put in the sheet, so the item stays off rather than opening an empty one.
    @Test("An engine with no editable facet offers no Edit")
    func noEditableFacetRefused() {
        let bare = context(
            supportsSchemaOwner: false,
            supportsSchemaPrivileges: false,
            supportsRenameSchema: false
        )
        #expect(!SchemaEditEligibility.hasEditableFacet(bare))
        #expect(SchemaEditEligibility.editable([schema], context: bare) == nil)
    }

    @Test("Any one facet is enough to open the sheet")
    func oneFacetIsEnough() {
        let ownerOnly = context(
            supportsSchemaPrivileges: false,
            supportsRenameSchema: false
        )
        #expect(SchemaEditEligibility.editable([schema], context: ownerOnly) == schema)
    }
}
