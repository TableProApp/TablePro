import Foundation
@testable import TableProInfluxDBCore
import Testing

private let markedStatements: [(String, InfluxGeneration, InfluxQueryLanguage, String)] = [
    ("-- sql\nSELECT 1", .v3, .sql, "\nSELECT 1"),
    ("-- influxql\nSHOW MEASUREMENTS", .v2, .influxQL, "\nSHOW MEASUREMENTS"),
    ("// flux\nfrom(bucket: \"b\")", .v2, .flux, "\nfrom(bucket: \"b\")"),
    ("-- flux\nfrom(bucket: \"b\")", .v2, .flux, "\nfrom(bucket: \"b\")"),
    ("// influxql\nSHOW MEASUREMENTS", .v3, .influxQL, "\nSHOW MEASUREMENTS"),
    ("\n  -- InfluxQL  \nSELECT * FROM cpu\nLIMIT 1", .v3, .influxQL, "\n\nSELECT * FROM cpu\nLIMIT 1"),
    ("-- influxql\nfrom(bucket: \"b\") |> range(start: -1h)", .v2, .influxQL, "\nfrom(bucket: \"b\") |> range(start: -1h)"),
    ("// flux\nSELECT * FROM cpu", .v2, .flux, "\nSELECT * FROM cpu"),
]

private let unmarkedV3Statements: [(String, InfluxQueryLanguage)] = [
    ("SELECT * FROM cpu", .sql),
    ("SHOW TABLES", .sql),
    ("SHOW MEASUREMENTS", .influxQL),
    ("show tag keys from cpu", .influxQL),
    ("SELECT mean(usage) FROM cpu GROUP BY time(5m)", .influxQL),
    ("SELECT * FROM cpu WHERE time > now() - 1h", .influxQL),
    ("SELECT * FROM cpu WHERE note = 'GROUP BY time(5m)'", .sql),
    ("SELECT * FROM cpu WHERE note = 'now() - 1h'", .sql),
    ("SELECT 1 AS \"GROUP BY time(5m)\"", .sql),
]

private let unmarkedV2Statements: [(String, InfluxQueryLanguage)] = [
    ("from(bucket: \"metrics\")\n  |> range(start: -1h)", .flux),
    ("// last hour\nfrom(bucket: \"metrics\") |> range(start: -1h)", .flux),
    ("from(bucket: \"metrics\")", .flux),
    ("import \"strings\"\nstrings.toUpper(v: \"a\")", .flux),
    ("SELECT * FROM cpu WHERE note = 'a |> b'", .influxQL),
    ("SELECT * FROM cpu", .influxQL),
    ("SHOW MEASUREMENTS", .influxQL),
]

private let v2Statements: [String] = markedStatements.filter { $0.1 == .v2 }.map { $0.0 }
    + unmarkedV2Statements.map { $0.0 }

private let pingBody = Data(
    #"{"product_name":"InfluxDB 3 Core","version":"3.12.2","revision":"cc9769917a","process_id":"189427e3-c06e-4d02-a9a5-70d920a9d41b"}"#
        .utf8
)

struct InfluxRoutingTests {
    @Test(arguments: markedStatements)
    func aFirstLineMarkerPicksTheLanguageAndIsBlanked(
        statement: String,
        generation: InfluxGeneration,
        language: InfluxQueryLanguage,
        text: String
    ) throws {
        let routed = try InfluxStatement.route(statement, generation: generation)
        #expect(routed == InfluxStatement(language: language, text: text))
        #expect(routed.text.components(separatedBy: "\n").count == statement.components(separatedBy: "\n").count)
    }

    @Test func aMarkerAfterTheFirstLineIsAnOrdinaryComment() throws {
        let statement = "SELECT 1\n-- influxql"
        #expect(try InfluxStatement.route(statement, generation: .v3) == InfluxStatement(language: .sql, text: statement))
    }

    @Test(arguments: unmarkedV3Statements)
    func unmarkedV3TextRoutesSQLUnlessItUsesInfluxQLOnlySyntax(statement: String, language: InfluxQueryLanguage) throws {
        let routed = try InfluxStatement.route(statement, generation: .v3)
        #expect(routed == InfluxStatement(language: language, text: statement))
    }

    @Test(arguments: unmarkedV2Statements)
    func unmarkedV2TextRoutesFluxOnlyWhenItLooksLikeFlux(statement: String, language: InfluxQueryLanguage) throws {
        let routed = try InfluxStatement.route(statement, generation: .v2)
        #expect(routed == InfluxStatement(language: language, text: statement))
    }

    @Test(arguments: [
        ("-- sql\nSELECT 1", InfluxGeneration.v2, InfluxQueryLanguage.sql),
        ("from(bucket: \"b\") |> range(start: -1h)", .v3, .flux),
        ("// flux\nfrom(bucket: \"b\")", .v3, .flux),
    ])
    func aLanguageTheGenerationLacksIsRefused(
        statement: String,
        generation: InfluxGeneration,
        language: InfluxQueryLanguage
    ) {
        #expect(throws: InfluxError.unsupportedLanguage(language, generation: generation)) {
            try InfluxStatement.route(statement, generation: generation)
        }
    }

    @Test(arguments: v2Statements)
    func isFluxAgreesWithRouteOnV2(statement: String) throws {
        let routed = try InfluxStatement.route(statement, generation: .v2)
        #expect(InfluxStatement.isFlux(statement) == (routed.language == .flux))
    }

    @Test(arguments: InfluxQueryLanguage.allCases)
    func markedTextRoutesBackToItsLanguage(language: InfluxQueryLanguage) throws {
        let marked = InfluxStatement.marked("SELECT 1", language: language)
        #expect(marked == "-- \(language.rawValue)\nSELECT 1")
        let generation: InfluxGeneration = language == .flux ? .v2 : .v3
        #expect(try InfluxStatement.route(marked, generation: generation) == InfluxStatement(
            language: language,
            text: "\nSELECT 1"
        ))
    }

    @Test(arguments: [("v2.9.1", InfluxGeneration.v2), ("3.12.2", .v3), ("4.0.0", .v3)])
    func theGenerationComesFromTheVersionString(version: String, generation: InfluxGeneration) {
        #expect(InfluxGeneration(version: version) == generation)
    }

    @Test func aOneXServerIsRefusedByName() {
        #expect(throws: InfluxError.unsupportedVersion("1.11.8")) {
            try InfluxServerInfo(versionHeader: "1.11.8", pingBody: Data())
        }
    }

    @Test(arguments: ["", "abc", "1.11.8"])
    func aVersionWithoutAMajorNumberNamesNoGeneration(version: String) {
        #expect(InfluxGeneration(version: version) == nil)
    }

    @Test func theVersionHeaderNamesTheServer() throws {
        let info = try InfluxServerInfo(versionHeader: "v2.9.1", pingBody: Data())
        #expect(info == InfluxServerInfo(generation: .v2, version: "v2.9.1"))
    }

    @Test(arguments: [nil, ""] as [String?])
    func withoutAVersionHeaderThePingBodyNamesTheServer(header: String?) throws {
        let info = try InfluxServerInfo(versionHeader: header, pingBody: pingBody)
        #expect(info == InfluxServerInfo(generation: .v3, version: "3.12.2"))
    }

    @Test(arguments: [Data(), Data(#"{"error": "the request was not authenticated"}"#.utf8)])
    func neitherHeaderNorBodyNamingAVersionThrows(body: Data) {
        #expect(throws: InfluxError.unknownVersion) {
            try InfluxServerInfo(versionHeader: nil, pingBody: body)
        }
    }

    @Test(arguments: [
        "SELECT host FROM cpu WHERE host =~ /--/; DELETE FROM cpu",
        "SELECT host FROM cpu WHERE host =~ /it's/; DELETE FROM cpu",
        #"SELECT * FROM cpu WHERE "note" =~ /\\/ AND "note" =~ /; DELETE FROM cpu --/"#,
        "SELECT * FROM cpu WHERE host =~ /*/; DELETE FROM cpu",
        "SHOW MEASUREMENTS; SHOW DATABASES",
        "SELECT 'a;b' FROM cpu; DROP MEASUREMENT cpu",
    ])
    func influxQLHoldingASecondStatementIsRefused(statement: String) {
        #expect(throws: InfluxError.multipleStatements) {
            try InfluxStatement.route(statement, generation: .v2)
        }
    }

    @Test(arguments: [
        "SELECT * FROM cpu WHERE note =~ /a;b/",
        "SELECT * FROM cpu WHERE note = 'it\\'s; fine'",
        "SELECT * FROM \"a;b\"",
        "SELECT usage / 2 FROM cpu;",
        "SELECT * FROM cpu -- a; b",
        "SELECT * FROM cpu /* a; b */",
        "SELECT * FROM \"metrics\".\"autogen\"./cp;u/",
    ])
    func oneInfluxQLStatementRoutes(statement: String) throws {
        #expect(try InfluxStatement.route(statement, generation: .v2).language == .influxQL)
    }

    @Test func aQuoteInsideAFluxCommentDoesNotHideThePipeline() throws {
        let flux = "start = -1h // user's range\nfrom(bucket: \"metrics\") |> range(start: start)"
        #expect(try InfluxStatement.route(flux, generation: .v2).language == .flux)
        #expect(InfluxStatement.isFlux(flux))
    }

    @Test func aQuoteInsideAFluxRegexDoesNotHideThePipeline() throws {
        let flux = "p = /'/\nfrom(bucket: \"metrics\") |> range(start: -1h) |> filter(fn: (r) => r.host =~ p)"
        #expect(try InfluxStatement.route(flux, generation: .v2).language == .flux)
    }

    @Test func aLeadingBlockCommentHoldingASemicolonIsOneStatement() throws {
        let statement = "/* note\n; still a comment\n*/\nSHOW MEASUREMENTS"
        #expect(try InfluxStatement.route(statement, generation: .v2).language == .influxQL)
    }
}
