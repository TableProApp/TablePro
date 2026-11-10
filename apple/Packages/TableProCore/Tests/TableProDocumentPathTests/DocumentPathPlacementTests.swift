import Foundation
import Testing

@testable import TableProDocumentPath

struct DocumentPathPlacementTests {
    private func placed(
        _ value: Any,
        _ keys: [String],
        following stored: [String: Any]
    ) throws -> NSDictionary {
        var partial: [String: Any] = [:]
        try DocumentPathPlacement.place(value, atKeys: keys, in: &partial, following: stored)
        return partial as NSDictionary
    }

    @Test("a field stored as a nested object is set inside that object")
    func nestedSpelling() throws {
        let stored: [String: Any] = ["address": ["city": "Hanoi", "zip": "100000"]]
        let partial = try placed("Hue", ["address", "city"], following: stored)
        #expect(partial == ["address": ["city": "Hue"]] as NSDictionary)
    }

    @Test("a field stored under a literal dotted key is set under that key")
    func dottedSpelling() throws {
        let stored: [String: Any] = ["address.city": "Hanoi"]
        let partial = try placed("Hue", ["address", "city"], following: stored)
        #expect(partial == ["address.city": "Hue"] as NSDictionary)
    }

    @Test("a field the document holds under both spellings is set under both")
    func bothSpellings() throws {
        let stored: [String: Any] = ["address": ["city": "Hanoi"], "address.city": "Hue"]
        let partial = try placed("Da Nang", ["address", "city"], following: stored)
        #expect(partial == ["address": ["city": "Da Nang"], "address.city": "Da Nang"] as NSDictionary)
    }

    @Test("a mixed spelling is followed level by level")
    func mixedSpelling() throws {
        let stored: [String: Any] = ["a": ["b.c": 1]]
        let partial = try placed(2, ["a", "b", "c"], following: stored)
        #expect(partial == ["a": ["b.c": 2]] as NSDictionary)
    }

    @Test("a field the document lacks is nested where its keys split")
    func missingField() throws {
        let partial = try placed("Hue", ["address", "city"], following: ["name": "x"])
        #expect(partial == ["address": ["city": "Hue"]] as NSDictionary)
    }

    @Test("a key the schema declares with a dot stays one key")
    func dottedSchemaKey() throws {
        let partial = try placed(3, ["metrics", "cpu.usage"], following: [:])
        #expect(partial == ["metrics": ["cpu.usage": 3]] as NSDictionary)
    }

    @Test("a missing field joins the deepest object the document already has")
    func deepestExistingObject() throws {
        let stored: [String: Any] = ["address": ["geo": ["lat": 1]]]
        let partial = try placed(2, ["address", "geo", "lon"], following: stored)
        #expect(partial == ["address": ["geo": ["lon": 2]]] as NSDictionary)
    }

    @Test("clearing a field writes null at the spelling the document holds")
    func nullValue() throws {
        let partial = try placed(NSNull(), ["address", "city"], following: ["address.city": "Hanoi"])
        #expect(partial == ["address.city": NSNull()] as NSDictionary)
    }

    @Test("a field inside an array of objects cannot be placed")
    func insideArray() {
        let stored: [String: Any] = ["variants": [["sku": "a"], ["sku": "b"]]]
        #expect(throws: DocumentPathPlacement.InsideArray(path: "variants.sku")) {
            _ = try placed("c", ["variants", "sku"], following: stored)
        }
    }

    @Test("two fields of one object share it in the partial document")
    func siblings() throws {
        let stored: [String: Any] = ["address": ["city": "Hanoi", "zip": "1"]]
        var partial: [String: Any] = [:]
        try DocumentPathPlacement.place("Hue", atKeys: ["address", "city"], in: &partial, following: stored)
        try DocumentPathPlacement.place("2", atKeys: ["address", "zip"], in: &partial, following: stored)
        #expect(partial as NSDictionary == ["address": ["city": "Hue", "zip": "2"]] as NSDictionary)
    }

    @Test("set nests a value and refuses to pass through a scalar")
    func setAndRead() {
        var document: [String: Any] = ["a": 1]
        #expect(DocumentPathPlacement.set("x", atKeys: ["b", "c"], in: &document))
        #expect(DocumentPathPlacement.value(in: document, atKeys: ["b", "c"]) as? String == "x")
        #expect(!DocumentPathPlacement.set("y", atKeys: ["a", "c"], in: &document))
        #expect(DocumentPathPlacement.value(in: document, atKeys: ["a", "c"]) == nil)
    }
}
