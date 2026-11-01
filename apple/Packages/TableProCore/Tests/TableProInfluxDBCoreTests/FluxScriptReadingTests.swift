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

    @Test func theServerASTOfHiddenTo() throws {
        // import \"array\"\n/\"/\narray.from(rows: [{a: 1}]) |> to(bucket: \"x\")\n// \"
        let ast = Data(#"""
        {"ast":{"type":"Package","package":"main","files":[{"type":"File","package":null,"imports":[{"type":"ImportDeclaration",
        "as":null,"path":{"type":"StringLiteral","value":"array"}}],"body":[{"type":"ExpressionStatement","expression":{"type":"RegexpLiteral",
        "value":"\""}},{"type":"ExpressionStatement","expression":{"type":"PipeExpression","argument":{"type":"CallExpression",
        "callee":{"type":"MemberExpression","object":{"type":"Identifier","name":"array"},"property":{"type":"Identifier",
        "name":"from"}},"arguments":[{"type":"ObjectExpression","properties":[{"type":"Property","key":{"type":"Identifier",
        "name":"rows"},"value":{"type":"ArrayExpression","elements":[{"type":"ObjectExpression","properties":[{"type":"Property",
        "key":{"type":"Identifier","name":"a"},"value":{"type":"IntegerLiteral","value":"1"}}]}]}}]}]},"call":{"type":"CallExpression",
        "callee":{"type":"Identifier","name":"to"},"arguments":[{"type":"ObjectExpression","properties":[{"type":"Property",
        "key":{"type":"Identifier","name":"bucket"},"value":{"type":"StringLiteral","value":"x"}}]}]}}}],"eof":[{"text":"// \""}]}]}}
        """#.utf8)
        #expect(try FluxAST.reading(ast) == writesHere)
    }

    @Test func theServerASTOfRead() throws {
        // from(bucket: \"m\") |> range(start: -1h) |> filter(fn: (r) => r.host == \"a\") |> map(fn: (r) => ({r
        let ast = Data(#"""
        {"ast":{"type":"Package","package":"main","files":[{"type":"File","package":null,"imports":null,"body":[{"type":"ExpressionStatement",
        "expression":{"type":"PipeExpression","argument":{"type":"PipeExpression","argument":{"type":"PipeExpression",
        "argument":{"type":"CallExpression","callee":{"type":"Identifier","name":"from"},"arguments":[{"type":"ObjectExpression",
        "properties":[{"type":"Property","key":{"type":"Identifier","name":"bucket"},"value":{"type":"StringLiteral","value":"m"}}]}]},
        "call":{"type":"CallExpression","callee":{"type":"Identifier","name":"range"},"arguments":[{"type":"ObjectExpression",
        "properties":[{"type":"Property","key":{"type":"Identifier","name":"start"},"value":{"type":"UnaryExpression",
        "operator":"-","argument":{"type":"DurationLiteral","values":[{"magnitude":1,"unit":"h"}]}}}]}]}},"call":{"type":"CallExpression",
        "callee":{"type":"Identifier","name":"filter"},"arguments":[{"type":"ObjectExpression","properties":[{"type":"Property",
        "key":{"type":"Identifier","name":"fn"},"value":{"type":"FunctionExpression","params":[{"type":"Property","key":{"type":"Identifier",
        "name":"r"},"value":null}],"body":{"type":"BinaryExpression","operator":"==","left":{"type":"MemberExpression",
        "object":{"type":"Identifier","name":"r"},"property":{"type":"Identifier","name":"host"}},"right":{"type":"StringLiteral",
        "value":"a"}}}}]}]}},"call":{"type":"CallExpression","callee":{"type":"Identifier","name":"map"},"arguments":[{"type":"ObjectExpression",
        "properties":[{"type":"Property","key":{"type":"Identifier","name":"fn"},"value":{"type":"FunctionExpression",
        "params":[{"type":"Property","key":{"type":"Identifier","name":"r"},"value":null}],"body":{"type":"ParenExpression",
        "expression":{"type":"ObjectExpression","with":{"type":"Identifier","name":"r"},"properties":[{"type":"Property",
        "key":{"type":"Identifier","name":"host"},"value":{"type":"StringLiteral","value":"x"}},{"type":"Property","key":{"type":"Identifier",
        "name":"to"},"value":{"type":"IntegerLiteral","value":"2"}}]}}}}]}]}}}]}]}}
        """#.utf8)
        #expect(try FluxAST.reading(ast) == readsHere)
    }

    @Test func theServerASTOfAliasHttp() throws {
        // import h \"http\"\nh.post(url: \"x\", data: bytes(v: \"a\"))
        let ast = Data(#"""
        {"ast":{"type":"Package","package":"main","files":[{"type":"File","package":null,"imports":[{"type":"ImportDeclaration",
        "as":{"type":"Identifier","name":"h"},"path":{"type":"StringLiteral","value":"http"}}],"body":[{"type":"ExpressionStatement",
        "expression":{"type":"CallExpression","callee":{"type":"MemberExpression","object":{"type":"Identifier","name":"h"},
        "property":{"type":"Identifier","name":"post"}},"arguments":[{"type":"ObjectExpression","properties":[{"type":"Property",
        "key":{"type":"Identifier","name":"url"},"value":{"type":"StringLiteral","value":"x"}},{"type":"Property","key":{"type":"Identifier",
        "name":"data"},"value":{"type":"CallExpression","callee":{"type":"Identifier","name":"bytes"},"arguments":[{"type":"ObjectExpression",
        "properties":[{"type":"Property","key":{"type":"Identifier","name":"v"},"value":{"type":"StringLiteral","value":"a"}}]}]}}]}]}}]}]}}
        """#.utf8)
        #expect(try FluxAST.reading(ast) == writesOutside)
    }

    @Test func theServerASTOfShorthandHost() throws {
        // host = \"h\"\nbuckets(host)
        let ast = Data(#"""
        {"ast":{"type":"Package","package":"main","files":[{"type":"File","package":null,"imports":null,"body":[{"type":"VariableAssignment",
        "id":{"type":"Identifier","name":"host"},"init":{"type":"StringLiteral","value":"h"}},{"type":"ExpressionStatement",
        "expression":{"type":"CallExpression","callee":{"type":"Identifier","name":"buckets"},"arguments":[{"type":"ObjectExpression",
        "properties":[{"type":"Property","key":{"type":"Identifier","name":"host"},"value":null}]}]}}]}]}}
        """#.utf8)
        #expect(try FluxAST.reading(ast) == readsOutside)
    }

    @Test func theServerASTOfQuotedHost() throws {
        // buckets(\"host\": \"h\")
        let ast = Data(#"""
        {"ast":{"type":"Package","package":"main","files":[{"type":"File","package":null,"imports":null,"body":[{"type":"ExpressionStatement",
        "expression":{"type":"CallExpression","callee":{"type":"Identifier","name":"buckets"},"arguments":[{"type":"ObjectExpression",
        "properties":[{"type":"Property","key":{"type":"StringLiteral","value":"host"},"value":{"type":"StringLiteral",
        "value":"h"}}]}]}}]}]}}
        """#.utf8)
        #expect(try FluxAST.reading(ast) == readsOutside)
    }

    @Test func theServerASTOfPackageValue() throws {
        // import \"influxdata/influxdb\"\nx = influxdb\nbuckets()
        let ast = Data(#"""
        {"ast":{"type":"Package","package":"main","files":[{"type":"File","package":null,"imports":[{"type":"ImportDeclaration",
        "as":null,"path":{"type":"StringLiteral","value":"influxdata/influxdb"}}],"body":[{"type":"VariableAssignment",
        "id":{"type":"Identifier","name":"x"},"init":{"type":"Identifier","name":"influxdb"}},{"type":"ExpressionStatement",
        "expression":{"type":"CallExpression","callee":{"type":"Identifier","name":"buckets"}}}]}]}}
        """#.utf8)
        #expect(try FluxAST.reading(ast) == writesOutside)
    }

    @Test func theServerASTOfCsvFile() throws {
        // import c \"csv\"\nc.from(mode: \"raw\", file: \"/x\")
        let ast = Data(#"""
        {"ast":{"type":"Package","package":"main","files":[{"type":"File","package":null,"imports":[{"type":"ImportDeclaration",
        "as":{"type":"Identifier","name":"c"},"path":{"type":"StringLiteral","value":"csv"}}],"body":[{"type":"ExpressionStatement",
        "expression":{"type":"CallExpression","callee":{"type":"MemberExpression","object":{"type":"Identifier","name":"c"},
        "property":{"type":"Identifier","name":"from"}},"arguments":[{"type":"ObjectExpression","properties":[{"type":"Property",
        "key":{"type":"Identifier","name":"mode"},"value":{"type":"StringLiteral","value":"raw"}},{"type":"Property","key":{"type":"Identifier",
        "name":"file"},"value":{"type":"StringLiteral","value":"/x"}}]}]}}]}]}}
        """#.utf8)
        #expect(try FluxAST.reading(ast) == readsOutside)
    }

    @Test func theServerASTOfMemberString() throws {
        // import \"influxdata/influxdb\"\nw = influxdb[\"wideTo\"]\nbuckets()
        let ast = Data(#"""
        {"ast":{"type":"Package","package":"main","files":[{"type":"File","package":null,"imports":[{"type":"ImportDeclaration",
        "as":null,"path":{"type":"StringLiteral","value":"influxdata/influxdb"}}],"body":[{"type":"VariableAssignment",
        "id":{"type":"Identifier","name":"w"},"init":{"type":"MemberExpression","object":{"type":"Identifier","name":"influxdb"},
        "property":{"type":"StringLiteral","value":"wideTo"}}},{"type":"ExpressionStatement","expression":{"type":"CallExpression",
        "callee":{"type":"Identifier","name":"buckets"}}}]}]}}
        """#.utf8)
        #expect(try FluxAST.reading(ast) == writesOutside)
    }

    @Test func theServerASTOfInterpolated() throws {
        // import \"array\"\nx = \"${array.from(rows: [{a: 1}]) |> to(bucket: \"x\")}\"\nbuckets()
        let ast = Data(#"""
        {"ast":{"type":"Package","package":"main","files":[{"type":"File","package":null,"imports":[{"type":"ImportDeclaration",
        "as":null,"path":{"type":"StringLiteral","value":"array"}}],"body":[{"type":"VariableAssignment","id":{"type":"Identifier",
        "name":"x"},"init":{"type":"StringExpression","parts":[{"type":"InterpolatedPart","expression":{"type":"PipeExpression",
        "argument":{"type":"CallExpression","callee":{"type":"MemberExpression","object":{"type":"Identifier","name":"array"},
        "property":{"type":"Identifier","name":"from"}},"arguments":[{"type":"ObjectExpression","properties":[{"type":"Property",
        "key":{"type":"Identifier","name":"rows"},"value":{"type":"ArrayExpression","elements":[{"type":"ObjectExpression",
        "properties":[{"type":"Property","key":{"type":"Identifier","name":"a"},"value":{"type":"IntegerLiteral","value":"1"}}]}]}}]}]},
        "call":{"type":"CallExpression","callee":{"type":"Identifier","name":"to"},"arguments":[{"type":"ObjectExpression",
        "properties":[{"type":"Property","key":{"type":"Identifier","name":"bucket"},"value":{"type":"StringLiteral","value":"x"}}]}]}}}]}},
        {"type":"ExpressionStatement","expression":{"type":"CallExpression","callee":{"type":"Identifier","name":"buckets"}}}]}]}}
        """#.utf8)
        #expect(try FluxAST.reading(ast) == writesHere)
    }

    @Test func anASTBodyThatIsNotJSONThrows() {
        #expect(throws: InfluxError.self) { try FluxAST.reading(Data("nope".utf8)) }
    }

    @Test(arguments: [
        "import \"array\"\nx = 1./ 2.0\narray.from(rows: [{a: 1}]) |> to(bucket: \"x\")\ny = 3.0 / 1.0",
        "import \"array\"\nb = \"x\"\nr = /a\\\\/ \"/\narray.from(rows: [{a: 1}]) |> to(bucket: b)\n// \"",
    ])
    func theLexerReadsFloatsAndRegexEscapesTheWayFluxDoes(script: String) {
        #expect(FluxScriptReading(script).writes)
    }
}
