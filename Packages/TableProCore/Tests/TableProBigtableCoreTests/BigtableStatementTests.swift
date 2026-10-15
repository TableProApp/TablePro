import Foundation
@testable import TableProBigtableCore
import Testing

struct BigtableStatementTests {
    private let nameColumn = BigtableColumn(family: "cf", qualifier: Data("name".utf8))

    @Test("Request lines read table, key, column, query and body")
    func requests() throws {
        let get = try BigtableRequest.parse("get events/user#42")
        #expect(get.verb == .get && get.table == "events" && get.key == Data("user#42".utf8))
        let quoted = try BigtableRequest.parse(#"DELETE events/"a b/c" profile:name"#)
        #expect(quoted.key == Data("a b/c".utf8) && quoted.column == "profile:name")
        let scan = try BigtableRequest.parse("SCAN events/user#?limit=20")
        #expect(scan.key == Data("user#".utf8) && scan.limit == 20)
        let put = try BigtableRequest.parse(#"PUT events/b64:AAE= {"cf:a": "1"}"#)
        #expect(put.key == Data([0, 1]) && put.body == #"{"cf:a": "1"}"#)
        let insert = try BigtableRequest.parse(#"INSERT events/k {"cf:a": "1"}"#)
        #expect(insert.verb == .insert && insert.key == Data("k".utf8))
        let read = try BigtableRequest.parse(#"READ events {"rowsLimit": "5"}"#)
        #expect(read.table == "events" && read.body == #"{"rowsLimit": "5"}"#)
    }

    @Test("A scan names a whole table with or without a slash")
    func scanWholeTable() throws {
        for text in ["SCAN events", "SCAN events/"] {
            let scan = try BigtableRequest.parse(text)
            #expect(scan.table == "events" && scan.key == nil && scan.limit == nil)
        }
        #expect(try BigtableRequest.parse("SCAN events?limit=5").limit == 5)
    }

    @Test("A scan limit is a whole number above zero, and no other query is taken")
    func scanLimits() {
        for text in ["SCAN events/?limit=0", "SCAN events/?limit=-5", "SCAN events/?limit=x", "SCAN events/?rows=5"] {
            #expect(throws: BigtableError.self, "\(text)") { try BigtableRequest.parse(text) }
        }
    }

    @Test("A column after the key may hold a space, and nothing after a request is ignored")
    func columnsAndTrailingText() throws {
        let spaced = try BigtableRequest.parse("DELETE events/k cf:first name")
        #expect(spaced.column == "cf:first name")
        #expect(try spaced.mutations() == [.deleteColumn(BigtableColumn(family: "cf", qualifier: Data("first name".utf8)))])
        for text in ["GET events/k extra", #"DELETE events/k "cf:a" extra"#, "SCAN events/a?limit=5 more"] {
            #expect(throws: BigtableError.self, "\(text)") { try BigtableRequest.parse(text) }
        }
    }

    @Test("Malformed requests explain the syntax")
    func malformed() {
        for text in [
            "SELECT * FROM t", "GET events/", "PUT events/k", #"GET events/"open"#, "READ events",
            #"READ {"rowsLimit": "5"}"#, "GET user#42"
        ] {
            #expect(throws: BigtableError.self, "\(text)") { try BigtableRequest.parse(text) }
        }
    }

    @Test("A request reads back from its own text, quoting keys and columns that need it")
    func roundTrip() throws {
        for key in [Data("user#42".utf8), Data("a b".utf8), Data([0xFF]), Data("x/y".utf8), Data("\"q".utf8)] {
            for column in ["cf:a", "cf:first name"] {
                let request = BigtableRequest(verb: .delete, table: "events", key: key, column: column)
                #expect(try BigtableRequest.parse(request.text) == request)
            }
        }
        let scan = BigtableRequest(verb: .scan, table: "events", key: Data("user#".utf8), limit: 20)
        #expect(scan.text == "SCAN events/user#?limit=20")
        #expect(try BigtableRequest.parse(scan.text) == scan)
        let spec = BigtableBrowseSpec(table: "t", filters: [BigtableFilterSpec(column: "_key", op: "=", value: "k")], limit: 5, offset: 10)
        #expect(try BigtableStatement.parse(BigtableStatement.encode(spec)) == .browse(spec))
    }

    @Test("A write body sets cells, deletes nulled ones under PUT, and writes numbers and booleans as text")
    func mutations() throws {
        let put = BigtableRequest(verb: .put, table: "t", key: Data("k".utf8), body: #"{"cf:name": null, "cf:n": 42, "cf:on": true, "cf:raw": "b64:AAE="}"#)
        #expect(try put.mutations() == [
            .setCell(BigtableColumn(family: "cf", qualifier: Data("n".utf8)), Data("42".utf8)),
            .deleteColumn(nameColumn),
            .setCell(BigtableColumn(family: "cf", qualifier: Data("on".utf8)), Data("true".utf8)),
            .setCell(BigtableColumn(family: "cf", qualifier: Data("raw".utf8)), Data([0, 1]))
        ])
        #expect(try BigtableRequest(verb: .delete, table: "t", key: Data("k".utf8)).mutations() == [.deleteRow])
    }

    @Test("INSERT only sets cells, and no write sends an empty mutation")
    func writeRefusals() {
        let key = Data("k".utf8)
        #expect(throws: BigtableError.self) { try BigtableRequest(verb: .insert, table: "t", key: key, body: #"{"cf:a": null}"#).mutations() }
        #expect(throws: BigtableError.self) { try BigtableRequest(verb: .put, table: "t", key: key, body: "{}").mutations() }
        #expect(throws: BigtableError.self) { try BigtableRequest(verb: .put, table: "t", key: key, body: #"{"cf:a": [1]}"#).mutations() }
    }
}

struct BigtableRowWritesTests {
    private let key = Data("k".utf8)

    @Test("A new row is an INSERT of its non-empty cells under its _key")
    func insert() throws {
        let request = try BigtableRowWrites.insert(
            table: "events", columns: ["_key", "cf:a", "cf:b", "cf:c"], values: [.text("k"), .text("1"), .absent, .bytes(Data([0xFF]))]
        )
        #expect(request.text == #"INSERT events/k {"cf:a":"1","cf:c":"b64:/w=="}"#)
    }

    @Test("A new row without a _key, or with nothing but one, is refused")
    func insertRefusals() {
        #expect(throws: BigtableError.self) {
            try BigtableRowWrites.insert(table: "events", columns: ["_key", "cf:a"], values: [.absent, .text("1")])
        }
        #expect(throws: BigtableError.self) {
            try BigtableRowWrites.insert(table: "events", columns: ["_key", "cf:a"], values: [.text("k"), .absent])
        }
    }

    @Test("An edit sends only the changed cells, and a removed cell as null")
    func update() throws {
        let request = try #require(try BigtableRowWrites.update(table: "events", key: key, changes: [("cf:a", .text("2")), ("cf:b", .absent)]))
        #expect(request.text == #"PUT events/k {"cf:a":"2","cf:b":null}"#)
        #expect(try BigtableRowWrites.update(table: "events", key: key, changes: []) == nil)
    }

    @Test("An edit to an existing row's key is refused, since Bigtable cannot rename a row")
    func keyChangeRefused() {
        #expect(throws: BigtableError.self) {
            try BigtableRowWrites.update(table: "events", key: key, changes: [("_key", .text("k2"))])
        }
    }

    @Test("A delete names the row's key")
    func delete() {
        #expect(BigtableRowWrites.delete(table: "events", key: Data("a b".utf8)).text == #"DELETE events/"a b""#)
    }
}
