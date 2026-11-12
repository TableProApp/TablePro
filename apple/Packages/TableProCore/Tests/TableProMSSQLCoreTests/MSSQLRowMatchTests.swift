import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLRowMatchTests {
    @Test("Character columns need the exact comparison", arguments: [
        "char", "varchar", "text", "VARCHAR", "varchar(20)", "char(4)", "varchar(max)", " varchar (10)",
        "nchar", "nvarchar(50)", "ntext", "sysname"
    ])
    func characterTypes(typeName: String) {
        #expect(MSSQLRowMatch.comparesText(typeName: typeName))
    }

    // The value of a number, a date or a binary column is not the text a cast to nvarchar prints.
    @Test("Other columns keep the plain comparison", arguments: [
        "varbinary(max)", "int", "decimal(10,2)", "datetime", "uniqueidentifier", "xml", "sql_variant", "", "textual"
    ])
    func otherTypes(typeName: String) {
        #expect(!MSSQLRowMatch.comparesText(typeName: typeName))
    }

    @Test("A column with no known type keeps the plain comparison")
    func unknownType() {
        #expect(!MSSQLRowMatch.comparesText(typeName: nil))
    }

    @Test("The exact comparison reads the stored text by code point")
    func exactText() {
        #expect(MSSQLRowMatch.exactText("[k]", equals: "?")
            == "CAST([k] AS NVARCHAR(MAX)) COLLATE Latin1_General_100_BIN2 = ?")
        #expect(MSSQLRowMatch.exactText("[k]", equals: "N'Weßels'")
            == "CAST([k] AS NVARCHAR(MAX)) COLLATE Latin1_General_100_BIN2 = N'Weßels'")
    }
}
