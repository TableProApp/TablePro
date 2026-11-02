import Foundation
@testable import TableProInfluxDBCore
import Testing

private let base = URL(string: "http://127.0.0.1:28086")!
private let token = InfluxCredentials.token("tp-token")

private func queryItems(ofForm body: Data?) -> [URLQueryItem]? {
    guard let body else { return nil }
    return URLComponents(string: "http://h/?" + (String(bytes: body, encoding: .utf8) ?? ""))?.queryItems
}

struct InfluxRequestTests {
    @Test func anInfluxQLFormBodyPercentEncodesTheSemicolon() throws {
        let statement = InfluxStatement(language: .influxQL, text: "SELECT * FROM cpu WHERE note = 'a;b'")
        let request = try InfluxRequests.query(
            statement, database: "metrics", organization: "tp", generation: .v2, credentials: token
        )
        #expect(request.method == "POST")
        #expect(request.path == "/query")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.headers["Accept"] == "application/json")
        let body = try #require(request.body)
        #expect(String(bytes: body, encoding: .utf8)
            == "q=SELECT%20%2A%20FROM%20cpu%20WHERE%20note%20%3D%20%27a%3Bb%27&db=metrics")
    }

    @Test func anInfluxQLFormBodyRoundTripsEveryReservedCharacter() throws {
        let text = "SHOW MEASUREMENTS; SELECT * FROM \"a+b\" WHERE t = 'x&y=z é'"
        let request = try InfluxRequests.query(
            InfluxStatement(language: .influxQL, text: text),
            database: "my db",
            organization: "",
            generation: .v2,
            credentials: token
        )
        let data = try #require(request.body)
        let body = try #require(String(bytes: data, encoding: .utf8))
        for raw in [";", "+", " ", "é", "'", "\""] {
            #expect(!body.contains(raw), "\(raw) left raw in \(body)")
        }
        #expect(body.components(separatedBy: "&").count == 2)
        #expect(queryItems(ofForm: request.body) == [URLQueryItem(name: "q", value: text), URLQueryItem(name: "db", value: "my db")])
    }

    @Test func anInfluxQLFormBodyOmitsAnEmptyDatabase() throws {
        let request = try InfluxRequests.query(
            InfluxStatement(language: .influxQL, text: "SHOW DATABASES"),
            database: "",
            organization: "",
            generation: .v2,
            credentials: .none
        )
        #expect(queryItems(ofForm: request.body) == [URLQueryItem(name: "q", value: "SHOW DATABASES")])
    }

    @Test func urlQueryItemsArePercentEncodedTheSameWay() throws {
        let request = InfluxRequest(
            method: "GET",
            path: "/query",
            query: [
                InfluxQueryItem("q", "SHOW MEASUREMENTS; SHOW DATABASES"),
                InfluxQueryItem("db", "a+b&c=d é"),
            ]
        )
        let url = try #require(request.url(base: base))
        #expect(url.absoluteString
            == "http://127.0.0.1:28086/query?q=SHOW%20MEASUREMENTS%3B%20SHOW%20DATABASES&db=a%2Bb%26c%3Dd%20%C3%A9")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [
            URLQueryItem(name: "q", value: "SHOW MEASUREMENTS; SHOW DATABASES"),
            URLQueryItem(name: "db", value: "a+b&c=d é"),
        ])
    }

    @Test func theRequestPathJoinsABasePath() throws {
        let request = InfluxRequest(method: "GET", path: "/ping")
        let url = try #require(request.url(base: URL(string: "https://h.example/influx/")!))
        #expect(url.absoluteString == "https://h.example/influx/ping")
    }

    @Test func aV3SQLQueryPostsJSONForCSV() throws {
        let request = try InfluxRequests.query(
            InfluxStatement(language: .sql, text: "SELECT note FROM cpu"),
            database: "metrics",
            organization: "",
            generation: .v3,
            credentials: token
        )
        #expect(request.method == "POST")
        #expect(request.path == "/api/v3/query_sql")
        #expect(request.query.isEmpty)
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Accept"] == "text/csv")
        let fields = try JSONDecoder().decode([String: String].self, from: try #require(request.body))
        #expect(fields == ["db": "metrics", "q": "SELECT note FROM cpu", "format": "csv"])
    }

    @Test func aV3QueryOmitsAnEmptyDatabase() throws {
        let request = try InfluxRequests.query(
            InfluxStatement(language: .influxQL, text: "SHOW DATABASES"),
            database: "",
            organization: "",
            generation: .v3,
            credentials: token
        )
        let fields = try JSONDecoder().decode([String: String].self, from: try #require(request.body))
        #expect(fields == ["q": "SHOW DATABASES", "format": "csv"])
    }

    @Test func aV3InfluxQLQueryGoesToTheInfluxQLEndpoint() throws {
        let request = try InfluxRequests.query(
            InfluxStatement(language: .influxQL, text: "SHOW MEASUREMENTS"),
            database: "metrics",
            organization: "",
            generation: .v3,
            credentials: token
        )
        #expect(request.path == "/api/v3/query_influxql")
        #expect(request.headers["Accept"] == "text/csv")
    }

    @Test func aV2FluxQueryPostsToTheQueryAPIWithTheOrganizationInTheURL() throws {
        let text = "from(bucket: \"metrics\") |> range(start: -1h)"
        let request = try InfluxRequests.query(
            InfluxStatement(language: .flux, text: text),
            database: "metrics",
            organization: "tp",
            generation: .v2,
            credentials: token
        )
        #expect(request.method == "POST")
        #expect(request.url(base: base)?.absoluteString == "http://127.0.0.1:28086/api/v2/query?org=tp")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Accept"] == "application/csv")
        let body = try #require(request.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["query"] as? String == text)
        #expect(object["type"] as? String == "flux")
        let dialect = try #require(object["dialect"] as? [String: Any])
        #expect(dialect["annotations"] as? [String] == ["datatype"])
        #expect(dialect["header"] as? Bool == true)
    }

    @Test(arguments: [
        (InfluxGeneration.v3, InfluxQueryLanguage.flux),
        (.v2, .sql),
    ])
    func aLanguageTheGenerationLacksIsRefused(generation: InfluxGeneration, language: InfluxQueryLanguage) {
        #expect(throws: InfluxError.unsupportedLanguage(language, generation: generation)) {
            try InfluxRequests.query(
                InfluxStatement(language: language, text: "x"),
                database: "metrics",
                organization: "tp",
                generation: generation,
                credentials: token
            )
        }
    }

    @Test func v3SendsBearer() throws {
        #expect(InfluxRequests.ping(credentials: token, generation: .v3).headers["Authorization"] == "Bearer tp-token")
        let request = try InfluxRequests.query(
            InfluxStatement(language: .sql, text: "SELECT 1"),
            database: "metrics",
            organization: "",
            generation: .v3,
            credentials: token
        )
        #expect(request.headers["Authorization"] == "Bearer tp-token")
        #expect(InfluxRequests.v3Databases(credentials: token).headers["Authorization"] == "Bearer tp-token")
    }

    @Test func v2SendsToken() throws {
        #expect(InfluxRequests.ping(credentials: token, generation: .v2).headers["Authorization"] == "Token tp-token")
        let request = try InfluxRequests.query(
            InfluxStatement(language: .flux, text: "buckets()"),
            database: "",
            organization: "tp",
            generation: .v2,
            credentials: token
        )
        #expect(request.headers["Authorization"] == "Token tp-token")
        #expect(InfluxRequests.v2Organizations(credentials: token).headers["Authorization"] == "Token tp-token")
    }

    @Test func beforeTheVersionIsKnownTheTokenGoesOutAsToken() {
        #expect(InfluxRequests.ping(credentials: token).headers["Authorization"] == "Token tp-token")
    }

    @Test(arguments: [nil, "", "  \n"] as [String?])
    func aBlankTokenSendsNoAuthorization(text: String?) throws {
        let credentials = InfluxCredentials(token: text)
        #expect(credentials == .none)
        #expect(InfluxRequests.ping(credentials: credentials, generation: .v3).headers["Authorization"] == nil)
        let request = try InfluxRequests.query(
            InfluxStatement(language: .sql, text: "SELECT 1"),
            database: "metrics",
            organization: "",
            generation: .v3,
            credentials: credentials
        )
        #expect(request.headers["Authorization"] == nil)
    }

    @Test func aTokenIsTrimmed() {
        #expect(InfluxCredentials(token: " tp-token\n") == token)
    }

    @Test func theV2TokenCheckListsOneBucketOfTheOrganization() {
        let request = InfluxRequests.v2TokenCheck(organization: "tp", credentials: token)
        #expect(request.method == "GET")
        #expect(request.url(base: base)?.absoluteString == "http://127.0.0.1:28086/api/v2/buckets?org=tp&limit=1")
        #expect(request.headers["Authorization"] == "Token tp-token")
    }

    @Test func theV3DatabaseListAsksForJSON() {
        let request = InfluxRequests.v3Databases(credentials: token)
        #expect(request.url(base: base)?.absoluteString == "http://127.0.0.1:28086/api/v3/configure/database?format=json")
    }

    @Test func v3DatabasesAreReadFromTheConfigureList() throws {
        let body = Data(#"[{"iox::database":"_internal"},{"iox::database":"metrics"}]"#.utf8)
        #expect(try InfluxCatalogDecoder.v3Databases(body) == ["_internal", "metrics"])
    }

    @Test func anInfluxQLFormBodyCarriesTheRetentionPolicy() throws {
        let request = try InfluxRequests.query(
            InfluxStatement(language: .influxQL, text: "SHOW MEASUREMENTS"),
            database: "telegraf",
            retentionPolicy: "weekly",
            organization: "",
            generation: .v2,
            credentials: token
        )
        #expect(queryItems(ofForm: request.body) == [
            URLQueryItem(name: "q", value: "SHOW MEASUREMENTS"),
            URLQueryItem(name: "db", value: "telegraf"),
            URLQueryItem(name: "rp", value: "weekly"),
        ])
    }

    @Test func theDBRPLookupNamesTheBucketThenItsID() throws {
        let base = try #require(URL(string: "http://h:8086"))
        let bucket = InfluxRequests.v2Bucket(named: "telegraf/weekly", organization: "tp", credentials: token)
        #expect(bucket.url(base: base)?.absoluteString == "http://h:8086/api/v2/buckets?org=tp&name=telegraf%2Fweekly")
        let mappings = InfluxRequests.v2DBRPs(bucketID: "6213", organization: "tp", credentials: token)
        #expect(mappings.url(base: base)?.absoluteString == "http://h:8086/api/v2/dbrps?org=tp&bucketID=6213")
        let found = Data(#"{"buckets":[{"id":"6213","name":"telegraf/weekly"}]}"#.utf8)
        #expect(try InfluxCatalogDecoder.v2BucketID(found) == "6213")
    }

    @Test func aSlashBucketMapsToItsDatabaseAndRetentionPolicy() throws {
        let body = Data(#"""
        {"content": [{"id": "6213", "database": "telegraf", "retention_policy": "weekly", "default": false, "virtual": true, "bucketID": "6213"}]}
        """#.utf8)
        #expect(try InfluxCatalogDecoder.v2InfluxQLTarget(body)
            == InfluxQLTarget(database: "telegraf", retentionPolicy: "weekly", isDefault: false))
    }

    @Test func aMadeDefaultMappingWinsOverTheVirtualOne() throws {
        let body = Data(#"""
        {"content": [
          {"id": "9624", "database": "renamed", "retention_policy": "autogen", "default": true, "virtual": true, "bucketID": "9624"},
          {"id": "1191", "database": "legacy_db", "retention_policy": "autogen", "default": true, "virtual": false, "bucketID": "9624"}
        ]}
        """#.utf8)
        #expect(try InfluxCatalogDecoder.v2InfluxQLTarget(body)
            == InfluxQLTarget(database: "legacy_db", retentionPolicy: "autogen"))
        #expect(try InfluxCatalogDecoder.v2InfluxQLTarget(Data(#"{"content": []}"#.utf8)) == nil)
    }

    @Test func v2OrganizationsAreReadByName() throws {
        let body = Data(#"""
        {"links": {"self": "/api/v2/orgs"},
         "orgs": [{"links": {"self": "/api/v2/orgs/c80dd54eb3945b1c"}, "id": "c80dd54eb3945b1c", "name": "tp",
           "description": "", "createdAt": "2026-11-01T00:00:00Z", "updatedAt": "2026-11-01T00:00:00Z"}]}
        """#.utf8)
        #expect(try InfluxCatalogDecoder.v2Organizations(body) == ["tp"])
    }

    @Test func v2BucketsAreReadByNameFromTabIndentedJSON() throws {
        let body = Data("""
        {
        \t"links": {"self": "/api/v2/buckets?descending=false&limit=100&offset=0&org=tp"},
        \t"buckets": [
        \t\t{"id": "4d6d0e288bf0273e", "orgID": "c80dd54eb3945b1c", "type": "system", "name": "_monitoring", "labels": []},
        \t\t{"id": "4d6d0e288bf0273f", "orgID": "c80dd54eb3945b1c", "type": "system", "name": "_tasks", "labels": []},
        \t\t{"id": "4d6d0e288bf0273e", "orgID": "c80dd54eb3945b1c", "type": "user", "name": "metrics",
        \t\t "retentionRules": [{"type": "expire", "everySeconds": 0, "shardGroupDurationSeconds": 604800}], "labels": []},
        \t\t{"id": "9624e5eea705cdda", "orgID": "c80dd54eb3945b1c", "type": "user", "name": "renamed", "labels": []}
        \t]
        }
        """.utf8)
        #expect(try InfluxCatalogDecoder.v2BucketNames(body) == ["_monitoring", "_tasks", "metrics", "renamed"])
    }

    @Test func junkCatalogBodiesThrowMalformedResponse() {
        let junk = Data("not json".utf8)
        #expect(throws: InfluxError.malformedResponse("not json")) { try InfluxCatalogDecoder.v3Databases(junk) }
        #expect(throws: InfluxError.malformedResponse("not json")) { try InfluxCatalogDecoder.v2Organizations(junk) }
        #expect(throws: InfluxError.malformedResponse("not json")) { try InfluxCatalogDecoder.v2BucketNames(junk) }
        let text = #"{"code":"unauthorized","message":"unauthorized access"}"#
        let wrongShape = Data(text.utf8)
        #expect(throws: InfluxError.malformedResponse(text)) { try InfluxCatalogDecoder.v2BucketNames(wrongShape) }
        #expect(throws: InfluxError.malformedResponse(text)) { try InfluxCatalogDecoder.v3Databases(wrongShape) }
    }
}
