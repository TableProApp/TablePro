import Foundation
@testable import TableProOracleCore
import Testing

/// `ALL_VIEWS.TEXT_VC` is `VARCHAR2(4000)` and cuts a longer view text mid-identifier, which Show DDL and a dump then
/// handed out as the whole view.
struct OracleViewDefinitionTests {
    @Test func testReadsTheStoredAndReturnedLengthsBesideTheText() {
        let sql = OracleSchemaQueries.viewDefinition(schema: "HR", view: "V")
        #expect(sql.hasPrefix("SELECT TEXT_VC, TEXT_LENGTH, LENGTHB(TEXT_VC) FROM"))
        #expect(sql.contains("VIEW_NAME = 'V' AND OWNER = 'HR'"))
    }

    /// Measured on Oracle 23 Free: a 160-column view read `TEXT_LENGTH` 6892 against `LENGTHB(TEXT_VC)` 4000.
    @Test func testALongerStoredTextIsTruncated() {
        #expect(OracleSchemaQueries.isViewTextTruncated(storedLength: "6892", returnedLength: "4000"))
    }

    /// Measured: a 58-byte Vietnamese text of 48 characters read 58 for both.
    @Test func testAWholeTextIsNotTruncated() {
        #expect(!OracleSchemaQueries.isViewTextTruncated(storedLength: "58", returnedLength: "58"))
        #expect(!OracleSchemaQueries.isViewTextTruncated(storedLength: " 29", returnedLength: "29 "))
    }

    @Test func testAnUnreadableLengthIsNotReportedAsTruncation() {
        #expect(!OracleSchemaQueries.isViewTextTruncated(storedLength: nil, returnedLength: "4000"))
        #expect(!OracleSchemaQueries.isViewTextTruncated(storedLength: "6892", returnedLength: nil))
    }
}
