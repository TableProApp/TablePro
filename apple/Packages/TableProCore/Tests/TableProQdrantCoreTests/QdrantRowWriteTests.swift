import Foundation
@testable import TableProQdrantCore
import Testing

struct QdrantRowWriteTests {
    private let types: [String: String] = [
        "id": "id", "city": "keyword", "count": "integer", "pop": "float", "active": "bool",
        "note": "string", "meta": "object", "payload.id": "keyword", "mixed": "json",
        "vector": "vector(2)", "vector.text": "multivector", "vector.sp": "sparse_vector"
    ]

    private func writes(_ changes: [QdrantRowChange]) throws -> [String] {
        try QdrantRowWriter.writes(
            collection: "docs",
            changes: changes,
            serverVersion: "1.20.0",
            typeName: { types[$0] },
            newID: { "00000000-0000-0000-0000-000000000001" }
        ).map(\.request.text)
    }

    private func refusal(_ change: QdrantRowChange) -> QdrantRowRefusal? {
        do {
            _ = try writes([change])
            return nil
        } catch {
            return error as? QdrantRowRefusal
        }
    }

    @Test("A payload edit is a set-payload request typed by the column the grid read")
    func payloadUpdate() throws {
        let change = QdrantRowChange(kind: .update, rowIndex: 0, id: "7", cells: [
            QdrantCell(column: "note", text: "42"),
            QdrantCell(column: "count", text: "42"),
            QdrantCell(column: "active", text: "1"),
            QdrantCell(column: "payload.id", text: "ext"),
            QdrantCell(column: "city", text: nil)
        ])
        #expect(try writes([change]) == [
            "POST /collections/docs/points/payload?wait=true\n"
                + #"{"payload":{"active":true,"city":null,"count":42,"id":"ext","note":"42"},"points":[7]}"#
        ])
    }

    @Test("Vector edits update or remove vectors by name, the unnamed one under the empty name")
    func vectorUpdate() throws {
        let change = QdrantRowChange(kind: .update, rowIndex: 0, id: "7", cells: [
            QdrantCell(column: "vector", text: "[0.5, 1]"),
            QdrantCell(column: "vector.sp", text: #"{"indices":[1],"values":[0.5]}"#),
            QdrantCell(column: "vector.text", text: nil)
        ])
        #expect(try writes([change]) == [
            "PUT /collections/docs/points/vectors?wait=true\n"
                + #"{"points":[{"id":7,"vector":{"":[0.5,1],"sp":{"indices":[1],"values":[0.5]}}}]}"#,
            "POST /collections/docs/points/vectors/delete?wait=true\n" + #"{"points":[7],"vector":["text"]}"#
        ])
    }

    @Test("A value that does not fit its column refuses the row instead of changing the field's type")
    func typeRefusals() {
        let count = QdrantRowChange(kind: .update, rowIndex: 3, id: "7", cells: [QdrantCell(column: "count", text: "4.5")])
        #expect(refusal(count) == QdrantRowRefusal(
            rowIndex: 3, reason: QdrantValueError.notAnInteger(column: "count", value: "4.5").errorDescription ?? ""
        ))
        let vector = QdrantRowChange(kind: .update, rowIndex: 1, id: "7", cells: [QdrantCell(column: "vector", text: "[\"a\"]")])
        #expect(refusal(vector)?.rowIndex == 1)
        let sparse = QdrantRowChange(kind: .update, rowIndex: 1, id: "7", cells: [QdrantCell(column: "vector.sp", text: "[1]")])
        #expect(refusal(sparse)?.rowIndex == 1)
    }

    @Test("A column whose type the grid did not report is refused, never written as text")
    func unknownType() {
        let change = QdrantRowChange(kind: .update, rowIndex: 2, id: "7", cells: [QdrantCell(column: "late", text: "43")])
        #expect(refusal(change)?.rowIndex == 2)
    }

    @Test("A delete names the point, and a row without an id or with a changed id is refused")
    func delete() throws {
        let uuid = "5c56c793-69f3-4fbf-87e6-c4bf54c28c26"
        #expect(try writes([QdrantRowChange(kind: .delete, rowIndex: 0, id: uuid)]) == [
            "POST /collections/docs/points/delete?wait=true\n{\"points\":[\"\(uuid)\"]}"
        ])
        #expect(refusal(QdrantRowChange(kind: .delete, rowIndex: 4, id: nil))?.rowIndex == 4)
        let idChange = QdrantRowChange(kind: .update, rowIndex: 5, id: "1", cells: [QdrantCell(column: "id", text: "2")])
        #expect(refusal(idChange)?.rowIndex == 5)
    }

    @Test("A json column saves the JSON its cell spells, so a quoted string stays a string")
    func jsonColumnValues() throws {
        func written(_ text: String) throws -> String? {
            try writes([QdrantRowChange(kind: .update, rowIndex: 0, id: "7", cells: [QdrantCell(column: "mixed", text: text)])]).first
        }
        let prefix = "POST /collections/docs/points/payload?wait=true\n"
        #expect(try written(#""42""#) == prefix + #"{"payload":{"mixed":"42"},"points":[7]}"#)
        #expect(try written("42") == prefix + #"{"payload":{"mixed":42},"points":[7]}"#)
        #expect(try written(#""[]""#) == prefix + #"{"payload":{"mixed":"[]"},"points":[7]}"#)
        #expect(try written(#"["a"]"#) == prefix + #"{"payload":{"mixed":["a"]},"points":[7]}"#)
    }

    @Test("A duplicated row's default marker asks for a new id instead of failing as one")
    func duplicatedRowGetsNewID() throws {
        let change = QdrantRowChange(kind: .insert, rowIndex: 0, id: nil, cells: [
            QdrantCell(column: "id", text: "__DEFAULT__"), QdrantCell(column: "city", text: "Hanoi")
        ])
        #expect(try writes([change]).first?.contains(#""id":"00000000-0000-0000-0000-000000000001""#) == true)
    }

    @Test("A server that would overwrite a taken id gets no grid insert")
    func insertNeedsConditionalUpsert() {
        let change = QdrantRowChange(kind: .insert, rowIndex: 6, id: nil, cells: [QdrantCell(column: "city", text: "Hanoi")])
        for version in ["1.14.1", nil] as [String?] {
            #expect(throws: QdrantRowRefusal.self) {
                _ = try QdrantRowWriter.writes(collection: "docs", changes: [change], serverVersion: version, typeName: { types[$0] })
            }
        }
        #expect(QdrantServerVersion.insertsWithoutOverwrite("1.15.0"))
        #expect(QdrantServerVersion.insertsWithoutOverwrite("2.0.1-dev"))
        #expect(!QdrantServerVersion.insertsWithoutOverwrite("1.9.7"))
    }

    @Test("An insert carries its vectors, keeps an existing id untouched, and first checks that the id is free")
    func insert() throws {
        let change = QdrantRowChange(kind: .insert, rowIndex: 0, id: nil, cells: [
            QdrantCell(column: "id", text: ""),
            QdrantCell(column: "city", text: "Hanoi"),
            QdrantCell(column: "active", text: "true"),
            QdrantCell(column: "note", text: nil),
            QdrantCell(column: "vector", text: "[1,2]")
        ])
        let write = try #require(try QdrantRowWriter.writes(
            collection: "docs", changes: [change], serverVersion: "1.20.0", typeName: { types[$0] },
            newID: { "00000000-0000-0000-0000-000000000001" }
        ).first)
        #expect(write.request.text == "PUT /collections/docs/points?wait=true\n"
            + #"{"points":[{"id":"00000000-0000-0000-0000-000000000001","payload":{"active":true,"city":"Hanoi"},"vector":{"":[1,2]}}],"update_filter":{"must":[{"has_id":[]}]}}"#)
        #expect(write.mustFindNothing?.text == "POST /collections/docs/points\n"
            + #"{"ids":["00000000-0000-0000-0000-000000000001"],"with_payload":false,"with_vector":false}"#)
        let check = try #require(write.landedCheck.flatMap(QdrantInsertCheck.decode))
        #expect(check.collection == "docs")
        #expect(check.id as? String == "00000000-0000-0000-0000-000000000001")
        #expect(canonical(check.payload) == #"{"active":true,"city":"Hanoi"}"#)
    }

    @Test("The landed check passes only for the point the insert wrote")
    func landedCheck() throws {
        let written: [String: Any] = ["city": "Hanoi", "count": 3]
        let same = QdrantPoint(id: 1, payload: ["count": 3, "city": "Hanoi"], vector: nil, score: nil)
        let other = QdrantPoint(id: 1, payload: ["city": "Paris"], vector: nil, score: nil)
        #expect(QdrantInsertCheck.landed(same, payload: written))
        #expect(!QdrantInsertCheck.landed(other, payload: written))
        #expect(!QdrantInsertCheck.landed(nil, payload: written))
    }

    @Test("Typed values: text stays text, JSON columns parse, and malformed structures are refused")
    func payloadValues() throws {
        #expect(try QdrantValue.payload("42", type: .keyword, column: "c") as? String == "42")
        #expect(try QdrantValue.payload("0", type: .bool, column: "c") as? Bool == false)
        #expect((try QdrantValue.payload("9007199254740993", type: .float, column: "c") as? NSNumber)?.int64Value == 9_007_199_254_740_993)
        #expect((try QdrantValue.payload("2.5", type: .float, column: "c") as? NSNumber)?.doubleValue == 2.5)
        #expect(try QdrantValue.payload(#"["a"]"#, type: .array, column: "c") as? [String] == ["a"])
        #expect(try QdrantValue.payload("42", type: .json, column: "c") as? Int == 42)
        #expect(try QdrantValue.payload("plain", type: .json, column: "c") as? String == "plain")
        #expect(throws: QdrantValueError.notAnObject(column: "c")) { try QdrantValue.payload("not json", type: .object, column: "c") }
        #expect(throws: QdrantValueError.notAGeoPoint(column: "c")) { try QdrantValue.payload("{\"x\":1}", type: .geo, column: "c") }
    }
}
