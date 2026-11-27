import Foundation
import TableProConnectionLibrary
import Testing

struct LibraryFileRecordsTests {
    private struct Row: Codable, Equatable {
        let id: Int
        let name: String
    }

    private struct IdOnly: Decodable, Equatable {
        let id: Int
    }

    private static let unreadable =
        #"{"id":"seven","port":5432,"ratio":0.25,"flags":[true,null],"nested":{"big":9007199254740993}}"#

    @Test("A record that does not decode is kept and written back after the others, as it was")
    func unreadableRecordIsWrittenBack() throws {
        let data = Data(#"[{"id":1,"name":"One"},\#(Self.unreadable),{"id":2,"name":"Two"}]"#.utf8)

        let records = try LibraryFileRecords<Row>(decoding: data)
        #expect(records.elements == [Row(id: 1, name: "One"), Row(id: 2, name: "Two")])
        #expect(records.unreadable.count == 1)

        let written = try LibraryFileRecords.encoded([Row(id: 1, name: "One")], keeping: records.unreadable).data
        let rows = try #require(try JSONSerialization.jsonObject(with: written) as? [NSDictionary])
        let original = try #require(try JSONSerialization.jsonObject(with: Data(Self.unreadable.utf8)) as? NSDictionary)
        #expect(rows.count == 2)
        #expect(rows.last == original)
        #expect(try #require(String(bytes: written, encoding: .utf8)).contains("9007199254740993"))
        #expect(try LibraryFileRecords<Row>(decoding: written).elements == [Row(id: 1, name: "One")])
    }

    @Test("A save never writes over a kept record: one carrying its id is refused, and removing it by id is how it goes")
    func keptRecordKeepsItsId() throws {
        struct Named: Codable, Equatable {
            let id: UUID
            let name: String
        }
        let held = UUID()
        let other = UUID()
        let data = Data(#"[{"id":"\#(held.uuidString)","name":7},{"id":"\#(other.uuidString)","name":8}]"#.utf8)
        let records = try LibraryFileRecords<Named>(decoding: data)
        #expect(records.unreadable.map(\.id) == [held, other])

        #expect(throws: LibraryFileError.idHeldByUnreadableRecord(held)) {
            try LibraryFileRecords.encoded([Named(id: held, name: "Pulled")], keeping: records.unreadable)
        }

        let removed = try LibraryFileRecords.encoded([Named(id: held, name: "Pulled")], keeping: records.unreadable, removing: [held])
        #expect(removed.kept.map(\.id) == [other])
        let rows = try #require(try JSONSerialization.jsonObject(with: removed.data) as? [NSDictionary])
        #expect(rows.count == 2)
        #expect(rows.first?["name"] as? String == "Pulled")
        #expect(rows.last?["name"] as? Int == 8)
    }

    @Test("Entries that are not objects are kept too")
    func nonObjectEntriesAreKept() throws {
        let data = Data(#"[null,"text",{"id":1,"name":"One"},[1,2]]"#.utf8)

        let records = try LibraryFileRecords<Row>(decoding: data)

        #expect(records.elements == [Row(id: 1, name: "One")])
        #expect(records.unreadable == [.null, .string("text"), .array([.integer(1), .integer(2)])])
    }

    @Test("A decode-only type reads the records it can and skips the rest")
    func decodeOnlyElement() throws {
        let data = Data(#"[{"id":1},{"id":"x"},{"id":2,"extra":true}]"#.utf8)

        #expect(try LibraryFileRecords<IdOnly>(decoding: data).elements == [IdOnly(id: 1), IdOnly(id: 2)])
    }

    @Test("Data that is not a JSON array throws and is not a list", arguments: ["not json", "{\"id\":1}", "", "[{\"id\":1"])
    func notAListThrows(text: String) {
        let data = Data(text.utf8)

        #expect(throws: (any Error).self) {
            try LibraryFileRecords<Row>(decoding: data)
        }
        #expect(!LibraryFileRecords<Row>.isList(data))
    }

    @Test("Any JSON array is a list, whatever its records hold")
    func anyArrayIsAList() {
        #expect(LibraryFileRecords<Row>.isList(Data("[]".utf8)))
        #expect(LibraryFileRecords<Row>.isList(Data(#"[{"id":"x"},null]"#.utf8)))
    }
}
