import Foundation
@testable import TablePro
import Testing

struct QueryClassifierFluxTests {
    @Test func aFluxReadIsSafe() {
        let flux = """
        // last hour
        from(bucket: "metrics")
          |> range(start: -1h)
          |> filter(fn: (r) => r._measurement == "cpu")
        """
        #expect(QueryClassifier.classifyTier(flux, databaseType: .influxdb) == .safe)
        #expect(!QueryClassifier.isWriteQuery("buckets()", databaseType: .influxdb))
    }

    @Test func toAndWideToWrite() {
        let copy = "from(bucket: \"a\") |> range(start: -1h) |> to(bucket: \"b\")"
        #expect(QueryClassifier.classifyTier(copy, databaseType: .influxdb) == .write)
        let wide = "import \"influxdata/influxdb\"\nfrom(bucket: \"a\") |> range(start: -1h) |> influxdb.wideTo(bucket: \"b\")"
        #expect(QueryClassifier.isWriteQuery(wide, databaseType: .influxdb))
    }

    @Test func aLanguageHintDecidesTheReading() {
        let influxQL = "-- influxql\nDELETE FROM \"cpu\" WHERE \"host\" = 'a |> b'"
        #expect(QueryClassifier.classifyTier(influxQL, databaseType: .influxdb) != .safe)
        let flux = "// flux\nfrom(bucket: \"a\") |> range(start: -1h) |> to(bucket: \"b\")"
        #expect(QueryClassifier.classifyTier(flux, databaseType: .influxdb) == .write)
    }

    @Test func anAliasedWriteStillWrites() {
        let flux = "write = to\nfrom(bucket: \"a\") |> range(start: -1h) |> write(bucket: \"b\")"
        #expect(QueryClassifier.classifyTier(flux, databaseType: .influxdb) == .write)
        let field = "from(bucket: \"a\") |> range(start: -1h) |> map(fn: (r) => ({r with to: 1}))"
        #expect(QueryClassifier.classifyTier(field, databaseType: .influxdb) == .safe)
    }

    @Test func aRenamedNetworkImportReachesOutside() {
        let flux = "import h \"http\"\nfrom(bucket: \"a\") |> range(start: -1h) |> map(fn: (r) => ({r with s: h.get(url: \"x\")}))"
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(flux, databaseType: .influxdb))
    }

    @Test func aStringOrCommentThatSpellsToDoesNotWrite() {
        let flux = "from(bucket: \"to(\") // |> to(bucket: \"x\")\n  |> range(start: -1h)"
        #expect(QueryClassifier.classifyTier(flux, databaseType: .influxdb) == .safe)
    }

    @Test func aNetworkPackageReachesOutside() {
        let flux = "import \"http\"\nfrom(bucket: \"a\") |> range(start: -1h) |> map(fn: (r) => ({r with s: http.post(url: \"x\")}))"
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(flux, databaseType: .influxdb))
    }

    @Test func influxQLAndSQLKeepTheSQLReading() {
        #expect(QueryClassifier.classifyTier("SELECT * FROM \"cpu\" LIMIT 10", databaseType: .influxdb) == .safe)
        #expect(QueryClassifier.classifyTier("SHOW MEASUREMENTS", databaseType: .influxdb) == .safe)
        #expect(QueryClassifier.classifyTier("DROP MEASUREMENT \"cpu\"", databaseType: .influxdb) == .destructive)
        #expect(QueryClassifier.isWriteQuery("SELECT * INTO \"copy\" FROM \"cpu\"", databaseType: .influxdb))
    }
}
