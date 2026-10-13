@testable import TableProMSSQLCore
import XCTest

final class MSSQLModuleHeaderTests: XCTestCase {
    func testReadsATwoPartName() throws {
        let header = try XCTUnwrap(MSSQLModuleHeader.parse("CREATE VIEW dbo.v AS SELECT 1 AS a", objectKeyword: "VIEW"))
        XCTAssertEqual(header.nameParts, ["dbo", "v"])
        XCTAssertEqual(header.nameRange, NSRange(location: 12, length: 5))
    }

    /// The stored batch keeps the comments before the header, and a comment can name another object.
    func testSkipsLeadingCommentsThatReadLikeAHeader() throws {
        let definition = "-- CREATE VIEW dbo.other AS\r\n/* outer /* nested */ CREATE VIEW x */\ncreate view [dbo].[v_dscp1]\r\nAS\r\nSELECT 1"
        let header = try XCTUnwrap(MSSQLModuleHeader.parse(definition, objectKeyword: "VIEW"))
        XCTAssertEqual(header.nameParts, ["dbo", "v_dscp1"])
        XCTAssertEqual((definition as NSString).substring(with: header.nameRange), "[dbo].[v_dscp1]")
    }

    func testUnquotesBracketedAndDoubleQuotedParts() throws {
        let header = try XCTUnwrap(MSSQLModuleHeader.parse("CREATE VIEW [we]]ird].\"a\"\"b\" AS SELECT 1", objectKeyword: "VIEW"))
        XCTAssertEqual(header.nameParts, ["we]ird", "a\"b"])
    }

    /// A period inside brackets is part of the name, not a separator.
    func testKeepsAPeriodInsideBrackets() throws {
        let header = try XCTUnwrap(MSSQLModuleHeader.parse("CREATE VIEW sales.[v.1] AS SELECT 1", objectKeyword: "VIEW"))
        XCTAssertEqual(header.nameParts, ["sales", "v.1"])
    }

    func testAllowsCommentsAndSpacesAroundTheParts() throws {
        let definition = "/*X*/ CrEaTe /*Y*/ VIEW dbo . v(a) AS SELECT 1 AS a;"
        let header = try XCTUnwrap(MSSQLModuleHeader.parse(definition, objectKeyword: "VIEW"))
        XCTAssertEqual(header.nameParts, ["dbo", "v"])
        XCTAssertEqual((definition as NSString).substring(with: header.nameRange), "dbo . v")
    }

    func testAcceptsCreateOrAlterAndAlter() {
        XCTAssertEqual(MSSQLModuleHeader.parse("CREATE OR ALTER VIEW v AS SELECT 1", objectKeyword: "VIEW")?.nameParts, ["v"])
        XCTAssertEqual(MSSQLModuleHeader.parse("ALTER VIEW s.v AS SELECT 1", objectKeyword: "VIEW")?.nameParts, ["s", "v"])
    }

    func testRefusesTextThatIsNotThatHeader() {
        XCTAssertNil(MSSQLModuleHeader.parse("SELECT 1", objectKeyword: "VIEW"))
        XCTAssertNil(MSSQLModuleHeader.parse("CREATE TABLE t (a int)", objectKeyword: "VIEW"))
        XCTAssertNil(MSSQLModuleHeader.parse("CREATE VIEWS v AS SELECT 1", objectKeyword: "VIEW"))
        XCTAssertNil(MSSQLModuleHeader.parse("CREATE VIEW db.dbo.v AS SELECT 1", objectKeyword: "VIEW"))
        XCTAssertNil(MSSQLModuleHeader.parse("CREATE VIEW [unterminated AS SELECT 1", objectKeyword: "VIEW"))
        XCTAssertNil(MSSQLModuleHeader.parse("", objectKeyword: "VIEW"))
    }

    /// Measured: after `sp_rename '[dbo].[v_old]', 'v_new'` the stored text still reads `CREATE VIEW dbo.v_old`.
    func testRenamesAStaleName() {
        let renamed = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW dbo.v_old AS SELECT 2 AS y\n",
            objectKeyword: "VIEW",
            schema: "dbo",
            name: "v_new"
        )
        XCTAssertEqual(renamed, "CREATE VIEW [dbo].[v_new] AS SELECT 2 AS y\n")
    }

    func testRenamesAStaleSchema() {
        let moved = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW dbo.v AS SELECT 1", objectKeyword: "VIEW", schema: "sales", name: "v"
        )
        XCTAssertEqual(moved, "CREATE VIEW [sales].[v] AS SELECT 1")
    }

    func testAnUnqualifiedStaleNameGainsItsSchema() {
        let renamed = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW v_old AS SELECT 1", objectKeyword: "VIEW", schema: "dbo", name: "v_new"
        )
        XCTAssertEqual(renamed, "CREATE VIEW [dbo].[v_new] AS SELECT 1")
    }

    func testLeavesACurrentHeaderAsWritten() {
        let definitions = [
            "-- owner: finance\r\ncreate view [dbo].[v] AS SELECT 1 -- trailing note\r\n",
            "CREATE VIEW v AS SELECT 1",
            "CREATE VIEW dbo.v AS SELECT 1",
        ]
        for definition in definitions {
            XCTAssertEqual(
                MSSQLModuleHeader.namingObject(in: definition, objectKeyword: "VIEW", schema: "dbo", name: "v"),
                definition
            )
        }
    }

    func testEscapesAClosingBracketInTheNewName() {
        let renamed = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW dbo.v AS SELECT 1", objectKeyword: "VIEW", schema: "dbo", name: "a]b"
        )
        XCTAssertEqual(renamed, "CREATE VIEW [dbo].[a]]b] AS SELECT 1")
    }

    func testLeavesUnreadableTextAlone() {
        let text = "SELECT 1"
        XCTAssertEqual(MSSQLModuleHeader.namingObject(in: text, objectKeyword: "VIEW", schema: "dbo", name: "v"), text)
    }
}
