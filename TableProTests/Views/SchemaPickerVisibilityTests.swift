//
//  SchemaPickerVisibilityTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("SchemaPickerControl visibility")
struct SchemaPickerVisibilityTests {
    @Test("shows the picker for a single-schema database")
    func visibleWithOneSchema() {
        #expect(SchemaPickerControl.shouldShow(schemaCount: 1))
    }

    @Test("shows the picker when multiple schemas exist")
    func visibleWithMultipleSchemas() {
        #expect(SchemaPickerControl.shouldShow(schemaCount: 2))
    }

    @Test("hides the picker while no schemas are known")
    func hiddenWithNoSchemas() {
        #expect(!SchemaPickerControl.shouldShow(schemaCount: 0))
    }
}
