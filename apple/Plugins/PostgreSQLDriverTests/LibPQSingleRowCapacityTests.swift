import CLibPQ
import Foundation
import TableProPluginKit
import Testing

struct LibPQSingleRowCapacityTests {
    private static let textOid: Oid = 25

    private func singleRowResult(columnCount: Int) throws -> OpaquePointer {
        let result = try #require(PQmakeEmptyPGresult(nil, PGRES_SINGLE_TUPLE))
        let names = (0..<columnCount).map { strdup("c\($0)") }
        defer { names.forEach { free($0) } }
        var attributes = names.map { name in
            PGresAttDesc(name: name, tableid: 0, columnid: 0, format: 0, typid: Self.textOid, typlen: -1, atttypmod: -1)
        }
        #expect(PQsetResultAttrs(result, Int32(columnCount), &attributes) != 0)
        for column in 0..<columnCount {
            var value = Array("v\(column)".utf8CString)
            let stored = value.withUnsafeMutableBufferPointer { buffer in
                PQsetvalue(result, 0, Int32(column), buffer.baseAddress, Int32(buffer.count - 1))
            }
            #expect(stored != 0)
        }
        return result
    }

    @Test("A row read in single-row mode is allocated at its column count, with no spare slots")
    func singleRowHasExactCapacity() throws {
        let result = try singleRowResult(columnCount: 20)
        defer { PQclear(result) }

        let row = LibPQPluginConnection.singleRow(of: result, oids: Array(repeating: UInt32(Self.textOid), count: 20))

        #expect(row.count == 20)
        #expect(row.first == .text("v0"))
        #expect(row.last == .text("v19"))
        #expect(row.capacity == row.count)
    }
}
