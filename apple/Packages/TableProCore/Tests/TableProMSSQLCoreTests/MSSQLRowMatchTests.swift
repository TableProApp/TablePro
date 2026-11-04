import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLRowMatchTests {
    @Test("char, varchar and text columns need the exact comparison", arguments: [
        "char", "varchar", "text", "VARCHAR", "varchar(20)", "char(4)", "varchar(max)", " varchar (10)"
    ])
    func narrowTextTypes(typeName: String) {
        #expect(MSSQLRowMatch.comparesNarrowText(typeName: typeName))
    }

    @Test("Unicode, binary and other columns keep the plain comparison", arguments: [
        "nchar", "nvarchar(50)", "ntext", "sysname", "varbinary(max)", "int", "uniqueidentifier", "xml", "", "textual"
    ])
    func otherTypes(typeName: String) {
        #expect(!MSSQLRowMatch.comparesNarrowText(typeName: typeName))
    }

    @Test("A column with no known type keeps the plain comparison")
    func unknownType() {
        #expect(!MSSQLRowMatch.comparesNarrowText(typeName: nil))
    }

    @Test("The exact comparison reads the stored text by code point")
    func exactText() {
        #expect(MSSQLRowMatch.exactText("[k]", equals: "?")
            == "CAST([k] AS NVARCHAR(MAX)) COLLATE Latin1_General_100_BIN2 = ?")
        #expect(MSSQLRowMatch.exactText("[k]", equals: "N'Weßels'")
            == "CAST([k] AS NVARCHAR(MAX)) COLLATE Latin1_General_100_BIN2 = N'Weßels'")
    }

    @Test("A reference compares as varchar, and as Unicode when the code page loses a character")
    func columnRules() {
        let narrow = "CAST(N'x' AS VARCHAR(MAX))"
        let lossless = "CAST(\(narrow) AS NVARCHAR(MAX)) COLLATE Latin1_General_100_BIN2 = N'x'"
        #expect(MSSQLRowMatch.columnRules("[k]", equals: "N'x'")
            == "(([k] = \(narrow) AND \(lossless)) OR ([k] = N'x' AND NOT \(lossless)))")
    }
}
