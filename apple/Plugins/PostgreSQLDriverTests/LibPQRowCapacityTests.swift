import CLibPQ
import Foundation
import TableProPluginKit
import Testing

struct LibPQRowCapacityTests {
    private static let textOid: Oid = 25

    private func chunk(rows rowCount: Int, columns columnCount: Int) throws -> OpaquePointer {
        let result = try #require(PQmakeEmptyPGresult(nil, PGRES_TUPLES_CHUNK))
        let names = (0..<columnCount).map { strdup("c\($0)") }
        defer { names.forEach { free($0) } }
        var attributes = names.map { name in
            PGresAttDesc(name: name, tableid: 0, columnid: 0, format: 0, typid: Self.textOid, typlen: -1, atttypmod: -1)
        }
        #expect(PQsetResultAttrs(result, Int32(columnCount), &attributes) != 0)
        for row in 0..<rowCount {
            for column in 0..<columnCount {
                var value = Array("r\(row)c\(column)".utf8CString)
                let stored = value.withUnsafeMutableBufferPointer { buffer in
                    PQsetvalue(result, Int32(row), Int32(column), buffer.baseAddress, Int32(buffer.count - 1))
                }
                #expect(stored != 0)
            }
        }
        return result
    }

    @Test("Each row of a chunk is read at its own index and allocated at its column count, with no spare slots")
    func chunkRowsHaveExactCapacity() throws {
        let result = try chunk(rows: 3, columns: 20)
        defer { PQclear(result) }
        let oids = Array(repeating: UInt32(Self.textOid), count: 20)

        let rows = (0..<PQntuples(result)).map { LibPQPluginConnection.row($0, of: result, oids: oids) }

        #expect(rows.map(\.first) == [.text("r0c0"), .text("r1c0"), .text("r2c0")])
        #expect(rows.last?.last == .text("r2c19"))
        for row in rows {
            #expect(row.count == 20)
            #expect(row.capacity == row.count)
        }
    }
}
