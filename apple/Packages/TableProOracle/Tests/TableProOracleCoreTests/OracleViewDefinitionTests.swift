import Foundation
@testable import TableProOracleCore
import Testing

// `ALL_VIEWS.TEXT_VC` came with 12.1 and stops at 4,000 bytes: on 11g every table's DDL failed with ORA-00904, since
// a table is looked up as a view first, and a longer view had no definition at all.
struct OracleViewDefinitionTests {
    @Test func testReadsTheWholeTextFromTheLongColumn() {
        let sql = OracleSchemaQueries.viewDefinition(schema: "HR", view: "V")
        #expect(sql.hasPrefix("SELECT TEXT FROM"))
        #expect(!sql.contains("TEXT_VC"))
        #expect(sql.contains("VIEW_NAME = 'V' AND OWNER = 'HR'"))
    }
}
