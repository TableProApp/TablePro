import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLModuleHeaderTests {
    @Test func testReadsATwoPartName() throws {
        let header = try #require(MSSQLModuleHeader.parse("CREATE VIEW dbo.v AS SELECT 1 AS a", objectKeyword: "VIEW"))
        #expect(header.nameParts == ["dbo", "v"])
        #expect(header.nameRange == NSRange(location: 12, length: 5))
    }

    /// The stored batch keeps the comments before the header, and a comment can name another object.
    @Test func testSkipsLeadingCommentsThatReadLikeAHeader() throws {
        let definition = "-- CREATE VIEW dbo.other AS\r\n/* outer /* nested */ CREATE VIEW x */\ncreate view [dbo].[v_dscp1]\r\nAS\r\nSELECT 1"
        let header = try #require(MSSQLModuleHeader.parse(definition, objectKeyword: "VIEW"))
        #expect(header.nameParts == ["dbo", "v_dscp1"])
        #expect((definition as NSString).substring(with: header.nameRange) == "[dbo].[v_dscp1]")
    }

    @Test func testUnquotesBracketedAndDoubleQuotedParts() throws {
        let header = try #require(MSSQLModuleHeader.parse("CREATE VIEW [we]]ird].\"a\"\"b\" AS SELECT 1", objectKeyword: "VIEW"))
        #expect(header.nameParts == ["we]ird", "a\"b"])
    }

    /// A period inside brackets is part of the name, not a separator.
    @Test func testKeepsAPeriodInsideBrackets() throws {
        let header = try #require(MSSQLModuleHeader.parse("CREATE VIEW sales.[v.1] AS SELECT 1", objectKeyword: "VIEW"))
        #expect(header.nameParts == ["sales", "v.1"])
    }

    @Test func testAllowsCommentsAndSpacesAroundTheParts() throws {
        let definition = "/*X*/ CrEaTe /*Y*/ VIEW dbo . v(a) AS SELECT 1 AS a;"
        let header = try #require(MSSQLModuleHeader.parse(definition, objectKeyword: "VIEW"))
        #expect(header.nameParts == ["dbo", "v"])
        #expect((definition as NSString).substring(with: header.nameRange) == "dbo . v")
    }

    @Test func testAcceptsCreateOrAlterAndAlter() {
        #expect(MSSQLModuleHeader.parse("CREATE OR ALTER VIEW v AS SELECT 1", objectKeyword: "VIEW")?.nameParts == ["v"])
        #expect(MSSQLModuleHeader.parse("ALTER VIEW s.v AS SELECT 1", objectKeyword: "VIEW")?.nameParts == ["s", "v"])
    }

    @Test func testRefusesTextThatIsNotThatHeader() {
        #expect(MSSQLModuleHeader.parse("SELECT 1", objectKeyword: "VIEW") == nil)
        #expect(MSSQLModuleHeader.parse("CREATE TABLE t (a int)", objectKeyword: "VIEW") == nil)
        #expect(MSSQLModuleHeader.parse("CREATE VIEWS v AS SELECT 1", objectKeyword: "VIEW") == nil)
        #expect(MSSQLModuleHeader.parse("CREATE VIEW db.dbo.v AS SELECT 1", objectKeyword: "VIEW") == nil)
        #expect(MSSQLModuleHeader.parse("CREATE VIEW [unterminated AS SELECT 1", objectKeyword: "VIEW") == nil)
        #expect(MSSQLModuleHeader.parse("", objectKeyword: "VIEW") == nil)
    }

    /// Measured: after `sp_rename '[dbo].[v_old]', 'v_new'` the stored text still reads `CREATE VIEW dbo.v_old`.
    @Test func testRenamesAStaleName() {
        let renamed = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW dbo.v_old AS SELECT 2 AS y\n",
            objectKeyword: "VIEW",
            schema: "dbo",
            name: "v_new"
        )
        #expect(renamed == "CREATE VIEW dbo.[v_new] AS SELECT 2 AS y\n")
    }

    @Test func testRenamesAStaleSchema() {
        let moved = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW dbo.v AS SELECT 1", objectKeyword: "VIEW", schema: "sales", name: "v"
        )
        #expect(moved == "CREATE VIEW [sales].v AS SELECT 1")
    }

    @Test func testKeepsWhatLiesBetweenTheParts() {
        let renamed = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW dbo /* keep this */ . old_name AS SELECT 1 AS n",
            objectKeyword: "VIEW",
            schema: "dbo",
            name: "new_name"
        )
        #expect(renamed == "CREATE VIEW dbo /* keep this */ . [new_name] AS SELECT 1 AS n")

        let both = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW dbo/*a*/./*b*/old AS SELECT 1", objectKeyword: "VIEW", schema: "sales", name: "new"
        )
        #expect(both == "CREATE VIEW [sales]/*a*/./*b*/[new] AS SELECT 1")
    }

    @Test func testAnUnqualifiedStaleNameGainsItsSchema() {
        let renamed = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW v_old AS SELECT 1", objectKeyword: "VIEW", schema: "dbo", name: "v_new"
        )
        #expect(renamed == "CREATE VIEW [dbo].[v_new] AS SELECT 1")
    }

    @Test func testLeavesACurrentHeaderAsWritten() {
        let definitions = [
            "-- owner: finance\r\ncreate view [dbo].[v] AS SELECT 1 -- trailing note\r\n",
            "CREATE VIEW v AS SELECT 1",
            "CREATE VIEW dbo.v AS SELECT 1",
        ]
        for definition in definitions {
            #expect(MSSQLModuleHeader.namingObject(in: definition, objectKeyword: "VIEW", schema: "dbo", name: "v") == definition)
        }
    }

    @Test func testEscapesAClosingBracketInTheNewName() {
        let renamed = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW dbo.v AS SELECT 1", objectKeyword: "VIEW", schema: "dbo", name: "a]b"
        )
        #expect(renamed == "CREATE VIEW dbo.[a]]b] AS SELECT 1")
    }

    @Test func testANewNameCannotCloseItsBracketsEarly() {
        let renamed = MSSQLModuleHeader.namingObject(
            in: "CREATE VIEW dbo.a AS SELECT 1", objectKeyword: "VIEW", schema: "dbo", name: "v]\u{0301}\nGO\nDROP TABLE t"
        )
        #expect(renamed == "CREATE VIEW dbo.[v]]\u{0301}\nGO\nDROP TABLE t] AS SELECT 1")
    }

    @Test func testLeavesUnreadableTextAlone() {
        let text = "SELECT 1"
        #expect(MSSQLModuleHeader.namingObject(in: text, objectKeyword: "VIEW", schema: "dbo", name: "v") == text)
    }
}
