import Foundation
import TableProSQLGrammar
import Testing

/// A `CASE` or an `END` that goes unread leaves the count of open constructs wrong, and the unit then ends at the wrong
/// `;`: too early, and the rest of its body is sent as statements of their own.
@Suite("PL/SQL unit tracker")
struct PLSQLUnitTrackerTests {
    private static let oracle = SQLLexicalReadings.resolve(databaseTypeId: "Oracle", declared: nil, session: nil)
        .execution

    private static func procedure(looping header: String) -> String {
        """
        CREATE OR REPLACE PROCEDURE p IS
        BEGIN
          \(header) LOOP
            NULL;
            BEGIN EXECUTE IMMEDIATE 'GRANT DBA TO mallory'; END;
          END LOOP;
        END;
        """
    }

    private func sent(_ script: String) -> [String] {
        SQLStatementScanner.allStatements(in: script, grammar: Self.oracle)
    }

    @Test("A CASE after the range operator opens a construct", arguments: [
        "1..CASE WHEN 1 = 1 THEN 3 ELSE 1 END * 2",
        "1 .. CASE WHEN 1 = 1 THEN 3 ELSE 1 END * 2",
        "n..CASE WHEN 1 = 1 THEN 3 ELSE 1 END * 2",
        "r.low..CASE WHEN 1 = 1 THEN 3 ELSE 1 END * 2",
        "f(1)..CASE WHEN 1 = 1 THEN 3 ELSE 1 END * 2",
        "1e0..CASE WHEN 1 = 1 THEN 3 ELSE 1 END * 2",
    ])
    func caseAfterRangeOperator(bounds: String) {
        let unit = Self.procedure(looping: "FOR i IN \(bounds)")
        #expect(sent(unit + "\nSELECT 1 FROM dual;") == [unit, "SELECT 1 FROM dual"])
    }

    @Test("The END of a CASE that ends a loop header closes the CASE, not a loop", arguments: [
        "FOR i IN 1..CASE WHEN 1 = 1 THEN 3 ELSE 1 END",
        "FOR i IN 1..(CASE WHEN 1 = 1 THEN 3 ELSE 1 END) + CASE WHEN 1 = 1 THEN 3 ELSE 1 END",
        "FOR i IN 1..CASE WHEN 1 = 1 THEN 3 ELSE 1 END WHILE i < 2",
        "WHILE n < CASE WHEN 1 = 1 THEN 3 ELSE 1 END",
        "FOR r IN (SELECT a FROM t WHERE b = CASE WHEN 1 = 1 THEN 1 END FOR UPDATE)",
    ])
    func caseEndingLoopHeader(header: String) {
        let unit = Self.procedure(looping: header)
        #expect(sent(unit + "\nSELECT 1 FROM dual;") == [unit, "SELECT 1 FROM dual"])
    }

    @Test("A FOR that opens no loop leaves END LOOP and END IF closing theirs")
    func forOutsideLoopHeader() {
        let unit = """
            DECLARE
              CURSOR c IS SELECT a FROM t FOR UPDATE;
              r SYS_REFCURSOR;
            BEGIN
              LOOP
                IF 1 = 1 THEN
                  OPEN r FOR SELECT a FROM t;
                END IF;
                SELECT a INTO n FROM t FOR UPDATE;
              END LOOP;
            END;
            """
        #expect(sent(unit + "\nSELECT 1 FROM dual;") == [unit, "SELECT 1 FROM dual"])
    }

    @Test("An END after a number written with a trailing point closes its construct", arguments: ["2. END", "2.END"])
    func endAfterTrailingDecimalPoint(ending: String) {
        let unit = "BEGIN\n  x := CASE WHEN y = 1 THEN 1. ELSE \(ending);\nEND;"
        #expect(sent(unit + "\nSELECT 1 FROM dual;") == [unit, "SELECT 1 FROM dual"])
    }

    @Test("A word after a member access is still a name", arguments: [
        "v.END", "v . END", "t1.END", "v(1).END", "\"v\".END", "v.w.END", "v.CASE",
    ])
    func memberNamesAreUnchanged(member: String) {
        let unit = "BEGIN\n  x := \(member);\nEND;"
        #expect(sent(unit + "\nSELECT 1 FROM dual;") == [unit, "SELECT 1 FROM dual"])
    }
}
