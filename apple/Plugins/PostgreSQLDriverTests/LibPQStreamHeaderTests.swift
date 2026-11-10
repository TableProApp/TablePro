import CLibPQ
import Foundation
import TableProPluginKit
import Testing

struct LibPQStreamHeaderTests {
    private func connection() -> LibPQPluginConnection {
        LibPQPluginConnection(host: "localhost", port: 5_432, user: "postgres", password: nil, database: "postgres")
    }

    private func emptyResult(columns: [(name: String, oid: Oid)]) throws -> OpaquePointer {
        let result = try #require(PQmakeEmptyPGresult(nil, PGRES_TUPLES_OK))
        let names = columns.map { strdup($0.name) }
        defer { names.forEach { free($0) } }
        var attributes = zip(names, columns).map { name, column in
            PGresAttDesc(name: name, tableid: 0, columnid: 0, format: 0, typid: column.oid, typlen: -1, atttypmod: -1)
        }
        #expect(PQsetResultAttrs(result, Int32(attributes.count), &attributes) != 0)
        return result
    }

    @Test("The result that ends a stream describes its rows, so an empty one still has a header")
    func zeroRowResultCarriesTheRowDescription() {
        #expect(LibPQPluginConnection.carriesRowDescription(PGRES_TUPLES_OK))
        #expect(LibPQPluginConnection.carriesRowDescription(PGRES_SINGLE_TUPLE))
    }

    @Test("A command and a failure describe no rows")
    func otherResultsCarryNone() {
        #expect(!LibPQPluginConnection.carriesRowDescription(PGRES_COMMAND_OK))
        #expect(!LibPQPluginConnection.carriesRowDescription(PGRES_FATAL_ERROR))
        #expect(!LibPQPluginConnection.carriesRowDescription(PGRES_COPY_OUT))
    }

    @Test("A zero-row result yields its column names and types")
    func headerOfAnEmptyResult() throws {
        let result = try emptyResult(columns: [(name: "id", oid: 23), (name: "name", oid: 25)])
        defer { PQclear(result) }
        #expect(PQntuples(result) == 0)

        let described = connection().streamHeader(from: result)

        #expect(described.header.columns == ["id", "name"])
        #expect(described.header.columnTypeNames == ["integer", "text"])
        #expect(described.columnOids == [23, 25])
    }
}
