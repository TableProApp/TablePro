import Foundation
import TableProOracleCore
import Testing

struct OracleDropStatementsTests {
    private let release19c = OracleServerRelease(major: 19, update: 3)
    private let release23ai = OracleServerRelease(major: 23, update: 4)

    @Test func dropIfExistsArrivesIn23ai() {
        #expect(!OracleServerRelease(major: 21).hasDropIfExists)
        #expect(OracleServerRelease(major: 23).hasDropIfExists)
        #expect(OracleServerRelease(major: 23, update: 26).hasDropIfExists)
    }

    @Test func aTableBefore23aiDropsInABlockThatIgnoresOnlyAMissingTable() {
        let sql = OracleDropStatements.drop(.table, name: "ORDERS", schema: "APP", currentSchema: "APP", release: release19c)

        #expect(sql == """
            BEGIN
              EXECUTE IMMEDIATE 'DROP TABLE "ORDERS"';
            EXCEPTION
              WHEN OTHERS THEN
                IF SQLCODE != -942 THEN
                  RAISE;
                END IF;
            END;
            """)
    }

    @Test(arguments: [
        (OracleDropStatements.Object.view, "DROP VIEW", -942),
        (.materializedView, "DROP MATERIALIZED VIEW", -12_003),
        (.trigger, "DROP TRIGGER", -4_080),
    ])
    func eachKindIgnoresItsOwnMissingObjectError(object: OracleDropStatements.Object, verb: String, code: Int) {
        let sql = OracleDropStatements.drop(object, name: "X", schema: nil, currentSchema: "APP", release: release19c)

        #expect(sql.contains("EXECUTE IMMEDIATE '\(verb) \"X\"';"))
        #expect(sql.contains("IF SQLCODE != \(code) THEN"))
        #expect(object.missingObjectCode == code)
    }

    @Test(arguments: OracleDropStatements.Object.allCases)
    func from23aiTheDropTakesIfExists(object: OracleDropStatements.Object) {
        let sql = OracleDropStatements.drop(object, name: "X", schema: "APP", currentSchema: "APP", release: release23ai)

        #expect(sql.hasPrefix("DROP "))
        #expect(sql.hasSuffix(" IF EXISTS \"X\""))
        #expect(!sql.contains("BEGIN"))
    }

    @Test func aTriggerFrom23aiDrops() {
        #expect(OracleDropStatements.drop(.trigger, name: "TRG", schema: "HR", currentSchema: "APP", release: release23ai)
            == #"DROP TRIGGER IF EXISTS "HR"."TRG""#)
    }

    @Test func anUnknownReleaseGetsTheBlockEveryReleaseRuns() {
        let sql = OracleDropStatements.drop(.view, name: "V", schema: nil, currentSchema: nil, release: nil)

        #expect(sql.hasPrefix("BEGIN"))
        #expect(sql.contains("EXECUTE IMMEDIATE 'DROP VIEW \"V\"';"))
    }

    @Test func anObjectAnotherSchemaOwnsIsQualified() {
        let sql = OracleDropStatements.drop(.table, name: "T", schema: "HR", currentSchema: "APP", release: release19c)

        #expect(sql.contains("EXECUTE IMMEDIATE 'DROP TABLE \"HR\".\"T\"';"))
    }

    @Test func aBlankSchemaMeansTheCurrentOne() {
        let sql = OracleDropStatements.drop(.table, name: "T", schema: "  ", currentSchema: "APP", release: release23ai)

        #expect(sql == #"DROP TABLE IF EXISTS "T""#)
    }

    @Test func aQuoteInTheNameIsDoubledInsideTheLiteral() {
        let sql = OracleDropStatements.drop(.table, name: "it's", schema: nil, currentSchema: nil, release: release19c)

        #expect(sql.contains("EXECUTE IMMEDIATE 'DROP TABLE \"it''s\"';"))
    }
}
