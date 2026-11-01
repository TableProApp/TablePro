import Foundation
@testable import TablePro
import Testing

struct QueryClassifierFluxTests {
    @Test func aFluxReadIsSafe() {
        let flux = """
        // last hour
        from(bucket: "metrics")
          |> range(start: -1h)
          |> filter(fn: (r) => r._measurement == "cpu" and r.host =~ /^web-\\//)
        """
        #expect(QueryClassifier.classifyTier(flux, databaseType: .influxdb) == .safe)
        #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(flux, databaseType: .influxdb))
        #expect(!QueryClassifier.isWriteQuery("buckets()", databaseType: .influxdb))
    }

    @Test func toAndWideToWrite() {
        let copy = "from(bucket: \"a\") |> range(start: -1h) |> to(bucket: \"b\")"
        #expect(QueryClassifier.classifyTier(copy, databaseType: .influxdb) == .write)
        let wide = "import \"influxdata/influxdb\"\nfrom(bucket: \"a\") |> range(start: -1h) |> influxdb.wideTo(bucket: \"b\")"
        #expect(QueryClassifier.isWriteQuery(wide, databaseType: .influxdb))
        let indexed = "import \"influxdata/influxdb\"\nw = influxdb[\"wideTo\"]\nfrom(bucket: \"a\") |> range(start: -1h) |> w(bucket: \"b\")"
        #expect(QueryClassifier.isWriteQuery(indexed, databaseType: .influxdb))
    }

    @Test func aRegexEndingInAnEscapedSlashDoesNotHideAWrite() {
        let flux = "from(bucket:\"a\") |> range(start:-1h) |> filter(fn:(r)=> r.p =~ /x\\//) |> to(bucket:\"b\")"
        #expect(QueryClassifier.classifyTier(flux, databaseType: .influxdb) == .write)
    }

    @Test func eitherMarkerStyleDecidesTheReading() {
        let influxQL = "-- influxql\nDELETE FROM \"cpu\" WHERE \"host\" = 'a |> b'"
        #expect(QueryClassifier.classifyTier(influxQL, databaseType: .influxdb) != .safe)
        for marker in ["// flux", "-- flux"] {
            let flux = "\(marker)\nfrom(bucket: \"a\") |> range(start: -1h) |> to(bucket: \"b\")"
            #expect(QueryClassifier.classifyTier(flux, databaseType: .influxdb) == .write)
        }
    }

    @Test func theGridsOwnStatementsReadAsSQL() {
        let grid = "-- sql\nSELECT * FROM \"cpu\" WHERE \"note\" ~ 'a |> b' ORDER BY time DESC LIMIT 100 OFFSET 0"
        #expect(QueryClassifier.classifyTier(grid, databaseType: .influxdb) == .safe)
        let influxQL = "-- influxql\nSELECT * FROM \"cpu\" WHERE \"note\" = 'from(x)' ORDER BY time DESC LIMIT 100 OFFSET 0"
        #expect(QueryClassifier.classifyTier(influxQL, databaseType: .influxdb) == .safe)
    }

    @Test func anAliasedWriteStillWrites() {
        let flux = "write = to\nfrom(bucket: \"a\") |> range(start: -1h) |> write(bucket: \"b\")"
        #expect(QueryClassifier.classifyTier(flux, databaseType: .influxdb) == .write)
        let field = "from(bucket: \"a\") |> range(start: -1h) |> map(fn: (r) => ({r with to: 1}))"
        #expect(QueryClassifier.classifyTier(field, databaseType: .influxdb) == .safe)
    }

    @Test func aStringOrCommentThatSpellsToDoesNotWrite() {
        let flux = "from(bucket: \"to(\") // |> to(bucket: \"x\")\n  |> range(start: -1h)"
        #expect(QueryClassifier.classifyTier(flux, databaseType: .influxdb) == .safe)
    }

    @Test(arguments: [
        "import h \"http\"\nfrom(bucket: \"a\") |> range(start: -1h) |> map(fn: (r) => ({r with s: h.get(url: \"x\")}))",
        "import \"experimental/influxdb\"\ninfluxdb.api(method: \"post\", path: \"/api/v2/delete\", host: \"http://localhost:8086\")",
        "import \"influxdata/influxdb/monitor\"\nfrom(bucket: \"a\") |> range(start: -1h) |> monitor.check(data: {}, messageFn: (r) => \"\")",
        "import \"experimental/prometheus\"\nprometheus.scrape(url: \"http://169.254.169.254/\")",
        "import \"influxdata/influxdb/sample\"\nsample.data(set: \"airSensor\")",
    ])
    func anUnlistedPackageWritesAndReachesOutside(_ flux: String) {
        #expect(QueryClassifier.classifyTier(flux, databaseType: .influxdb) == .write)
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(flux, databaseType: .influxdb))
    }

    @Test func aRemoteHostOrServerFileReachesOutside() {
        let remote = "from(bucket: \"a\", host: \"http://10.0.0.1:8086\", token: \"t\") |> range(start: -1h)"
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(remote, databaseType: .influxdb))
        let file = "import c \"csv\"\nc.from(mode: \"raw\", file: \"/etc/passwd\")"
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(file, databaseType: .influxdb))
        let renamedTag = "from(bucket: \"a\") |> range(start: -1h) |> map(fn: (r) => ({r with host: \"x\"}))"
        #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(renamedTag, databaseType: .influxdb))
    }

    @Test func influxQLAndSQLKeepTheSQLReading() {
        #expect(QueryClassifier.classifyTier("SELECT * FROM \"cpu\" LIMIT 10", databaseType: .influxdb) == .safe)
        #expect(QueryClassifier.classifyTier("SHOW MEASUREMENTS", databaseType: .influxdb) == .safe)
        #expect(QueryClassifier.classifyTier("DROP MEASUREMENT \"cpu\"", databaseType: .influxdb) == .destructive)
        #expect(QueryClassifier.isWriteQuery("SELECT * INTO \"copy\" FROM \"cpu\"", databaseType: .influxdb))
    }

    @Test func eachStatementIsReadAsTheDriverReceivesIt() {
        let hidden = "-- flux\n;\nDELETE FROM cpu"
        #expect(QueryClassifier.classifyTier(hidden, databaseType: .influxdb) == .write)
        #expect(QueryClassifier.isDangerousQuery(hidden, databaseType: .influxdb))
        let control = "\u{1}\n-- flux\nSELECT = 1\nto(tables: from(bucket: \"metrics\"), bucket: \"target\")"
        #expect(QueryClassifier.isWriteQuery(control, databaseType: .influxdb))
        let mixed = "SHOW MEASUREMENTS;\nfrom(bucket: \"a\") |> range(start: -1h) |> to(bucket: \"b\")"
        #expect(QueryClassifier.classifyTier(mixed, databaseType: .influxdb) == .write)
    }
}
