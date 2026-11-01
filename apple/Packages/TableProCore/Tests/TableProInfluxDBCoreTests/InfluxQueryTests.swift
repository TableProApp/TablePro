import Foundation
@testable import TableProInfluxDBCore
import Testing

struct InfluxQueryTests {
    @Test(arguments: [
        ("v2.9.1", InfluxGeneration.v2),
        ("3.12.2", .v3),
        ("1.11.8", .v1),
        ("", .v3),
    ])
    func generationComesFromTheVersionHeader(header: String, expected: InfluxGeneration) {
        #expect(InfluxGeneration(versionHeader: header) == expected)
    }

    @Test func v3RoutesSQLByDefaultAndInfluxQLOnlyStatementsToInfluxQL() throws {
        #expect(try InfluxLanguageRouter.language(for: "SELECT * FROM cpu", generation: .v3) == .sql)
        #expect(try InfluxLanguageRouter.language(for: "show measurements", generation: .v3) == .influxQL)
        #expect(try InfluxLanguageRouter.language(
            for: "SELECT mean(usage) FROM cpu WHERE time > now() - 1h GROUP BY time(5m)", generation: .v3
        ) == .influxQL)
        #expect(try InfluxLanguageRouter.language(for: "SHOW TABLES", generation: .v3) == .sql)
    }

    @Test func v2RoutesFluxPipelinesToFluxAndTheRestToInfluxQL() throws {
        let flux = "// last hour\nfrom(bucket: \"metrics\")\n  |> range(start: -1h)"
        #expect(try InfluxLanguageRouter.language(for: flux, generation: .v2) == .flux)
        #expect(try InfluxLanguageRouter.language(for: "SELECT * FROM cpu", generation: .v2) == .influxQL)
    }

    @Test func aFirstLineCommentNamesTheLanguage() throws {
        #expect(try InfluxLanguageRouter.language(for: "-- influxql\nSELECT * FROM cpu", generation: .v3) == .influxQL)
    }

    @Test func aLanguageTheServerLacksIsRefused() {
        #expect(throws: InfluxError.unsupportedLanguage(.flux, generation: .v3)) {
            try InfluxLanguageRouter.language(for: "from(bucket: \"x\") |> range(start: -1h)", generation: .v3)
        }
        #expect(throws: InfluxError.unsupportedLanguage(.sql, generation: .v2)) {
            try InfluxLanguageRouter.language(for: "-- sql\nSELECT 1", generation: .v2)
        }
    }

    @Test func browseQueryIsTheSameShapeInBothLanguages() {
        let sql = InfluxSelectBuilder.select(measurement: "cpu", columns: [], limit: 100, offset: 200, language: .sql)
        let influxQL = InfluxSelectBuilder.select(
            measurement: "cpu", columns: [], limit: 100, offset: 200, language: .influxQL
        )
        #expect(sql == #"SELECT * FROM "cpu" ORDER BY time DESC LIMIT 100 OFFSET 200"#)
        #expect(influxQL == sql)
    }

    @Test func sqlSelectsNamedColumnsAndSortsByAnyColumn() {
        let query = InfluxSelectBuilder.select(
            measurement: #"we"ird"#, columns: ["time", "host"], sorts: [InfluxSort(column: "host", ascending: true)],
            limit: 10, offset: 0, language: .sql
        )
        #expect(query == #"SELECT "time", "host" FROM "we""ird" ORDER BY "host" ASC LIMIT 10 OFFSET 0"#)
    }

    @Test func influxQLSortsByTimeOnly() {
        let byHost = InfluxSelectBuilder.select(
            measurement: "cpu", columns: ["time", "host"], sorts: [InfluxSort(column: "host", ascending: true)],
            limit: 10, offset: 0, language: .influxQL
        )
        #expect(byHost.hasSuffix("ORDER BY time DESC LIMIT 10 OFFSET 0"))
        let byTime = InfluxSelectBuilder.select(
            measurement: "cpu", columns: [], sorts: [InfluxSort(column: "time", ascending: true)],
            limit: 10, offset: 0, language: .influxQL
        )
        #expect(byTime.contains("ORDER BY time ASC"))
    }

    @Test func filtersRenderPerLanguage() {
        let filters = [
            InfluxFilter(column: "host", op: "=", value: "a'b", isText: true),
            InfluxFilter(column: "usage", op: ">=", value: "12.5"),
            InfluxFilter(column: "note", op: "CONTAINS", value: "a/b", isCaseSensitive: false, isText: true),
            InfluxFilter(column: "region", op: "IN", value: "eu, us", isText: true),
            InfluxFilter(column: "time", op: "BETWEEN", value: "2024-01-01T00:00:00Z", secondValue: "2025-01-01T00:00:00Z"),
        ]
        let sql = InfluxSelectBuilder.select(
            measurement: "cpu", columns: [], filters: filters, limit: 5, offset: 0, language: .sql
        )
        #expect(sql.contains(#""host" = 'a''b'"#))
        #expect(sql.contains(#""usage" >= 12.5"#))
        #expect(sql.contains(#""note" ~ '(?i)a/b'"#))
        #expect(sql.contains(#"("region" = 'eu' OR "region" = 'us')"#))
        #expect(sql.contains(#"("time" >= '2024-01-01T00:00:00Z' AND "time" <= '2025-01-01T00:00:00Z')"#))

        let influxQL = InfluxSelectBuilder.select(
            measurement: "cpu", columns: [], filters: filters, logicMode: "or", limit: 5, offset: 0, language: .influxQL
        )
        #expect(influxQL.contains(#""host" = 'a\'b'"#))
        #expect(influxQL.contains(#""note" =~ /(?i)a\/b/"#))
        #expect(influxQL.contains(" OR "))
    }

    @Test func countReadsTheLargestPerFieldCount() {
        let influxQL = InfluxResultTable(
            columns: ["time", "count_idle", "count_usage"], typeNames: [], rows: [["1970-01-01T00:00:00Z", "2", "3"]]
        )
        #expect(InfluxSelectBuilder.rowCount(from: influxQL) == 3)
        let sql = InfluxResultTable(columns: ["count(*)"], typeNames: [], rows: [["7"]])
        #expect(InfluxSelectBuilder.rowCount(from: sql) == 7)
        #expect(InfluxSelectBuilder.rowCount(from: .empty) == 0)
        let filter = InfluxFilter(column: "host", op: "=", value: "a", isText: true)
        #expect(InfluxSelectBuilder.count(measurement: "cpu", filters: [filter], language: .sql)
            == #"SELECT COUNT(*) FROM "cpu" WHERE "host" = 'a'"#)
    }

    @Test func nullChecksUseEmptyTagsOnInfluxQL() {
        let filter = InfluxFilter(column: "host", op: "IS NULL", value: "")
        #expect(InfluxSelectBuilder.condition(for: filter, language: .sql) == #""host" IS NULL"#)
        #expect(InfluxSelectBuilder.condition(for: filter, language: .influxQL) == #""host" = ''"#)
    }

    @Test func v3QueryPostsJSONAskingForCSV() throws {
        let request = InfluxRequests.query(
            "SELECT 1", language: .sql, database: "metrics", organization: "",
            generation: .v3, credentials: .token("t")
        )
        #expect(request.path == "/api/v3/query_sql")
        #expect(request.headers["Authorization"] == "Bearer t")
        let body = try #require(request.body)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(payload == ["db": "metrics", "q": "SELECT 1", "format": "csv"])
    }

    @Test func v2InfluxQLPostsAFormWithAnEncodedPlus() throws {
        let request = InfluxRequests.query(
            "SELECT a+b FROM x", language: .influxQL, database: "metrics", organization: "tp",
            generation: .v2, credentials: .token("t")
        )
        #expect(request.path == "/query")
        #expect(request.headers["Authorization"] == "Token t")
        let body = String(bytes: try #require(request.body), encoding: .utf8) ?? ""
        #expect(body == "q=SELECT%20a%2Bb%20FROM%20x&db=metrics")
    }

    @Test func v2FluxNamesTheOrganization() throws {
        let request = InfluxRequests.query(
            "buckets()", language: .flux, database: "", organization: "my org",
            generation: .v2, credentials: .token("t")
        )
        let url = try #require(request.url(base: URL(string: "http://h:8086")!))
        #expect(url.absoluteString == "http://h:8086/api/v2/query?org=my%20org")
    }

    @Test func pingCarriesTheTokenForAServerWithAuthOn() {
        #expect(InfluxRequests.ping(credentials: .token("t")).headers["Authorization"] == "Token t")
        #expect(InfluxRequests.ping(credentials: .none).headers.isEmpty)
    }

    @Test func containsEscapesRegexMetacharacters() {
        let filter = InfluxFilter(column: "host", op: "CONTAINS", value: "a.b(c)", isText: true)
        #expect(InfluxSelectBuilder.condition(for: filter, language: .sql) == #""host" ~ 'a\.b\(c\)'"#)
    }

    @Test func aBlankTokenSendsNoAuthorization() {
        #expect(InfluxCredentials(token: " \n") == .none)
        #expect(InfluxCredentials(token: "t").authorization(for: .v3) == "Bearer t")
    }

    @Test func catalogReadsDatabasesAndBuckets() throws {
        #expect(try InfluxCatalogDecoder.v3Databases(Data(#"[{"iox::database":"_internal"},{"iox::database":"metrics"}]"#.utf8))
            == ["_internal", "metrics"])
        let buckets = try InfluxCatalogDecoder.v2Buckets(Data(#"{"buckets":[{"id":"b1","name":"metrics"}]}"#.utf8))
        #expect(buckets.map(\.name) == ["metrics"])
        #expect(buckets.map(\.id) == ["b1"])
    }

    @Test func aMadeDefaultDBRPWinsOverTheVirtualOne() throws {
        let json = """
        {"content":[\
        {"bucketID":"b1","database":"metrics","default":true,"virtual":true},\
        {"bucketID":"b1","database":"legacy","default":true,"virtual":false},\
        {"bucketID":"b1","database":"other","default":false,"virtual":false},\
        {"bucketID":"b2","database":"logs","default":true,"virtual":true}]}
        """
        #expect(try InfluxCatalogDecoder.v2InfluxQLDatabases(Data(json.utf8)) == ["b1": "legacy", "b2": "logs"])
    }

    @Test func v3ColumnsMapArrowTypesAndPutTimeFirst() {
        let table = InfluxResultTable(
            columns: ["column_name", "data_type"],
            typeNames: ["string", "string"],
            rows: [
                ["host", "Dictionary(Int32, Utf8)"], ["idle", "Int64"], ["time", "Timestamp(ns)"],
                ["usage", "Float64"], ["ok", "Boolean"],
            ]
        )
        let columns = InfluxSchema.v3Columns(from: table)
        #expect(columns.map(\.name) == ["time", "host", "idle", "ok", "usage"])
        #expect(columns.map(\.typeName) == ["timestamp", "tag", "integer", "boolean", "float"])
    }

    @Test func v1ColumnsJoinTagAndFieldKeys() {
        let tags = InfluxResultTable(columns: ["tagKey"], typeNames: ["string"], rows: [["region"], ["host"]])
        let fields = InfluxResultTable(
            columns: ["fieldKey", "fieldType"], typeNames: ["string", "string"],
            rows: [["usage", "float"], ["idle", "integer"]]
        )
        let columns = InfluxSchema.v1Columns(tagKeys: tags, fieldKeys: fields)
        #expect(columns.map(\.name) == ["time", "host", "idle", "region", "usage"])
        #expect(columns.first { $0.name == "host" }?.isText == true)
    }
}
