import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("LibPQPluginError result fields")
struct LibPQPluginErrorTests {
    private static let undefinedFunctionFields: [Int32: String] = [
        Int32(UInt8(ascii: "C")): "42883",
        Int32(UInt8(ascii: "P")): "134",
        Int32(UInt8(ascii: "D")): "no function matches"
    ]

    private static func decoded(_ fields: [Int32: String], message: String = "ERROR: failed") -> LibPQPluginError {
        LibPQPluginError(message: message) { fields[$0] }
    }

    @Test("SQLSTATE comes from the C field, never the statement position")
    func sqlStateReadsTheSQLStateField() {
        let error = Self.decoded(Self.undefinedFunctionFields)
        #expect(error.sqlState == "42883")
        #expect(error.pluginSqlState == "42883")
    }

    @Test("Detail comes from the D field")
    func detailReadsTheDetailField() {
        let error = Self.decoded(Self.undefinedFunctionFields)
        #expect(error.detail == "no function matches")
    }

    @Test("Only the SQLSTATE and detail fields are read")
    func readsNoOtherField() {
        var requested: [Int32] = []
        _ = LibPQPluginError(message: "ERROR: failed") { field in
            requested.append(field)
            return nil
        }
        #expect(Set(requested) == [Int32(UInt8(ascii: "C")), Int32(UInt8(ascii: "D"))])
    }

    @Test("A result with no diagnostic fields carries no SQLSTATE")
    func missingFieldsStayNil() {
        let error = Self.decoded([:])
        #expect(error.sqlState == nil)
        #expect(error.detail == nil)
    }

    @Test("The error description names the SQLSTATE")
    func descriptionNamesTheSQLState() {
        let error = Self.decoded(
            Self.undefinedFunctionFields,
            message: "ERROR: function to_regclass(text) does not exist"
        )
        #expect(error.errorDescription?.contains("(SQLSTATE: 42883)") == true)
    }

    @Test("A decoded read-only transaction error is diagnosed as server-enforced read-only")
    func readOnlyTransactionIsDiagnosed() {
        let error = Self.decoded(
            [Int32(UInt8(ascii: "C")): "25006"],
            message: "ERROR: cannot execute INSERT in a read-only transaction"
        )
        #expect(DatabaseWriteRejectionDiagnosis.classify(error) != nil)
    }
}
