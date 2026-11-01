import Foundation
@testable import TableProInfluxDBCore
import Testing

private let readsHere = FluxScriptReading(writes: false, reachesOutside: false)
private let writesHere = FluxScriptReading(writes: true, reachesOutside: false)
private let readsOutside = FluxScriptReading(writes: false, reachesOutside: true)
private let writesOutside = FluxScriptReading(writes: true, reachesOutside: true)

struct FluxScriptReadingTests {
    @Test(arguments: [
        #"""
        from(bucket: "metrics")
            |> range(start: -1h)
            |> filter(fn: (r) => r._measurement == "cpu" and r["host"] == "a")
            |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
        """#,
        #"""
        import "strings"
        from(bucket: "metrics")
            |> range(start: -1h)
            |> filter(fn: (r) => strings.hasPrefix(v: r.host, prefix: "a"))
        """#,
        #"""
        import "csv"
        csv.from(csv: "a,b\n1,2\n", mode: "raw")
        """#,
    ])
    func aScriptThatOnlyReadsNeitherWritesNorReachesOutside(script: String) {
        #expect(FluxScriptReading(script) == readsHere)
    }

    @Test(arguments: [
        #"from(bucket: "a") |> range(start: -1h) |> to(bucket: "b")"#,
        #"""
        import "influxdata/influxdb"
        from(bucket: "a") |> range(start: -1h) |> influxdb.wideTo(bucket: "b")
        """#,
        #"""
        import "experimental"
        from(bucket: "a") |> range(start: -1h) |> experimental.to(bucket: "b")
        """#,
        #"""
        w = to
        from(bucket: "a") |> range(start: -1h) |> w(bucket: "b")
        """#,
        #"from(bucket: "a") |> range(start: -1h) |> filter(fn: (r) => r.p =~ /x\//) |> to(bucket: "b")"#,
        #"""
        t = from(bucket: "a") |> range(start: -1h)
        s = "written: ${to(tables: t, bucket: "b")}"
        """#,
    ])
    func aScriptNamingAWriterWrites(script: String) {
        #expect(FluxScriptReading(script) == writesHere)
    }

    @Test(arguments: [
        #"from(bucket: "a") |> range(start: -1h) |> map(fn: (r) => ({r with to: "x"}))"#,
        #"""
        import "date"
        from(bucket: "a") |> range(start: date.add(d: -1h, to: now()))
        """#,
        #"from(bucket: "a") |> range(start: -1h) |> filter(fn: (r) => r.note == "to(bucket: x)")"#,
        #"""
        // |> to(bucket: "b")
        from(bucket: "a") |> range(start: -1h)
        """#,
        #"from(bucket: "a") |> range(start: -1h) // |> to(bucket: "b")"#,
    ])
    func toAsALabelStringOrCommentDoesNotWrite(script: String) {
        #expect(FluxScriptReading(script) == readsHere)
    }

    @Test func indexingAPackageByAWriterNameWrites() {
        let script = #"""
        import "influxdata/influxdb"
        import "array"
        x = influxdb["wideTo"]
        array.from(rows: [{a: 1}])
        """#
        #expect(FluxScriptReading(script).writes)
    }

    @Test(arguments: [
        #"""
        import "influxdata/influxdb"
        x = influxdb
        from(bucket: "a") |> range(start: -1h)
        """#,
        #"""
        import "influxdata/influxdb"
        k = "wide" + "To"
        f = influxdb[k]
        """#,
    ])
    func aPackageBoundOrIndexedWritesAndReachesOutside(script: String) {
        #expect(FluxScriptReading(script) == writesOutside)
    }

    @Test(arguments: [
        #"""
        import "experimental/influxdb"
        influxdb.api(method: "get", path: "/health")
        """#,
        #"""
        import "influxdata/influxdb/monitor"
        monitor.from(start: -1h)
        """#,
        #"""
        import "http"
        http.post(url: "http://x", data: bytes(v: "x"))
        """#,
        #"""
        import "sql"
        sql.from(driverName: "postgres", dataSourceName: "postgresql://u@h/db", query: "SELECT 1")
        """#,
        #"""
        import "experimental/prometheus"
        prometheus.scrape(url: "http://x/metrics")
        """#,
        #"""
        import "contrib/anaisdg/statsmodels"
        from(bucket: "a") |> range(start: -1h)
        """#,
        #"""
        import "influxdata/influxdb/sample"
        sample.data(set: "airSensor")
        """#,
        #"""
        import "influxdata/influxdb/secrets"
        t = secrets.get(key: "token")
        """#,
        #"""
        import h "http"
        h.post(url: "http://x", data: bytes(v: "x"))
        """#,
    ])
    func anUnknownImportWritesAndReachesOutside(script: String) {
        #expect(FluxScriptReading(script) == writesOutside)
    }

    @Test(arguments: [
        #"from(bucket: "b", host: "http://x") |> range(start: -1h)"#,
        #"""
        import "csv"
        csv.from(file: "/etc/passwd")
        """#,
        #"""
        import c "csv"
        c.from(mode: "raw", file: "/x")
        """#,
        #"buckets("host": "http://remote:8086", org: "o", token: "t")"#,
        #"""
        host = "http://remote:8086"
        from(bucket: "b", host) |> range(start: -1h)
        """#,
        #"""
        import "csv"
        file = "/etc/passwd"
        csv.from(mode: "raw", file)
        """#,
    ])
    func aHostOrFileArgumentReachesOutsideWithoutWriting(script: String) {
        #expect(FluxScriptReading(script) == readsOutside)
    }

    @Test func aHostKeyInARecordDoesNotReachOutside() {
        let script = #"from(bucket: "a") |> range(start: -1h) |> map(fn: (r) => ({r with host: "x"}))"#
        #expect(FluxScriptReading(script) == readsHere)
    }

    @Test(arguments: [
        "r = /x\n\"/\ny = \"z\" |> to(bucket: \"c\")",
        "x = if true then 1else \"a\" |> to(bucket: \"c\")",
    ])
    func theLexerAgreesWithFluxOnRegexLinesAndNumbers(script: String) {
        #expect(FluxScriptReading(script).writes)
    }

    @Test func aNumberStopsWhereADurationDoesNot() {
        #expect(FluxLexer.tokens(of: "1then").map(\.kind) == [.number, .identifier])
        #expect(FluxLexer.tokens(of: "1h30m").map(\.kind) == [.number])
        #expect(FluxLexer.tokens(of: "1mo").map(\.kind) == [.number])
    }

    @Test(arguments: [
        "from(bucket: \"a",
        "x = /abc",
        "s = \"${1 + 1\"",
    ])
    func anUnclosedLiteralFailsClosed(script: String) {
        #expect(FluxScriptReading(script) == writesOutside)
    }
}
