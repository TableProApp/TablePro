import Foundation
import Testing

@testable import TableProMySQLCore

struct MySQLRoutineSignaturesTests {
    @Test("Parameters keep the order the read returns them in")
    func keepsDeclarationOrder() {
        var signatures = MySQLRoutineSignatures()
        signatures.append(schema: "app", type: "PROCEDURE", routine: "p", mode: "IN", name: "a", dataType: "int")
        signatures.append(schema: "app", type: "PROCEDURE", routine: "p", mode: "OUT", name: "b", dataType: "date")
        signatures.append(schema: "app", type: "PROCEDURE", routine: "p", mode: "INOUT", name: "c", dataType: "decimal(10,2)")

        #expect(signatures.signature(schema: "app", type: "PROCEDURE", routine: "p")
            == "(IN a int, OUT b date, INOUT c decimal(10,2))")
    }

    @Test("A function parameter has no mode and leaves no gap for it")
    func functionParameterHasNoMode() {
        var signatures = MySQLRoutineSignatures()
        signatures.append(schema: "app", type: "FUNCTION", routine: "f", mode: nil, name: "a", dataType: "int")
        signatures.append(schema: "app", type: "FUNCTION", routine: "f", mode: nil, name: "b", dataType: "varchar(64)")

        #expect(signatures.signature(schema: "app", type: "FUNCTION", routine: "f") == "(a int, b varchar(64))")
    }

    @Test("A routine the read listed nothing for takes no parameters")
    func unlistedRoutineIsEmpty() {
        #expect(MySQLRoutineSignatures().signature(schema: "app", type: "PROCEDURE", routine: "p") == "()")
    }

    /// A procedure and a function may share a name, and under `lower_case_table_names = 0` so may
    /// routines in `casedb` and `CASEDB`. Merged, the list read `(IN a int, IN z date, IN y date)`.
    @Test("Routines of another type or another database's spelling keep their own parameters")
    func doesNotMergeAcrossTypeOrSchema() {
        var signatures = MySQLRoutineSignatures()
        signatures.append(schema: "casedb", type: "PROCEDURE", routine: "shared", mode: "IN", name: "a", dataType: "int")
        signatures.append(schema: "CASEDB", type: "PROCEDURE", routine: "shared", mode: "IN", name: "z", dataType: "date")
        signatures.append(schema: "casedb", type: "FUNCTION", routine: "shared", mode: nil, name: "x", dataType: "text")

        #expect(signatures.signature(schema: "casedb", type: "PROCEDURE", routine: "shared") == "(IN a int)")
        #expect(signatures.signature(schema: "CASEDB", type: "PROCEDURE", routine: "shared") == "(IN z date)")
        #expect(signatures.signature(schema: "casedb", type: "FUNCTION", routine: "shared") == "(x text)")
    }

    @Test("The routine type matches whatever case the server spells it in")
    func typeIsCaseInsensitive() {
        var signatures = MySQLRoutineSignatures()
        signatures.append(schema: "app", type: "procedure", routine: "p", mode: "IN", name: "a", dataType: "int")

        #expect(signatures.signature(schema: "app", type: "PROCEDURE", routine: "p") == "(IN a int)")
    }

    /// `GROUP_CONCAT` stopped at `group_concat_max_len`, 1024 bytes on MySQL 8.4.13, and cut a
    /// 40-parameter list at `IN cu`.
    @Test("A long parameter list is kept whole")
    func longListIsNotTruncated() {
        var signatures = MySQLRoutineSignatures()
        for index in 0 ..< 40 {
            signatures.append(
                schema: "app",
                type: "PROCEDURE",
                routine: "long_sig",
                mode: "IN",
                name: "customer_reference_parameter_\(index)",
                dataType: "varchar(255)"
            )
        }
        let signature = signatures.signature(schema: "app", type: "PROCEDURE", routine: "long_sig")

        #expect(signature.utf8.count > 1_024)
        #expect(signature.hasSuffix("IN customer_reference_parameter_39 varchar(255))"))
    }
}
