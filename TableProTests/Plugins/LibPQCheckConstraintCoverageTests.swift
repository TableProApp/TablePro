//
//  LibPQCheckConstraintCoverageTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct LibPQCheckConstraintCoverageTests {
    @Test("No type offers check constraint editing without schema editing")
    func checkConstraintEditingNeedsSchemaEditing() {
        let inconsistent = DatabaseType.allKnownTypes.filter {
            $0.supportsCheckConstraintEditing && !$0.supportsSchemaEditing
        }
        #expect(inconsistent.isEmpty, "Check constraint editing on a read-only structure: \(inconsistent.map(\.rawValue))")
    }
}
