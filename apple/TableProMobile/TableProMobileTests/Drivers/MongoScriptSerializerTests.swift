import Foundation
import JavaScriptCore
@testable import TableProMobile
import Testing

struct MongoScriptSerializerTests {
    private func evaluate(_ script: String) throws -> String? {
        let context = try MongoScriptContext.make(execute: { _ in #"{"ok":true,"v":"app"}"# }, emit: { _ in true })
        return context.evaluateScript(script)?.toString()
    }

    @Test("A document's own toEJSON member is sent as the field it is", arguments: [
        (#"{"_id": {"toEJSON":MinKey}}"#, #"{"_id":{"toEJSON":{"$minKey":1}}}"#),
        (
            #"{"_id": {"shop":"berlin","number":"A-2","x":{"toEJSON":MaxKey()}}}"#,
            #"{"_id":{"shop":"berlin","number":"A-2","x":{"toEJSON":{"$maxKey":1}}}}"#
        ),
        (#"{"$set": {"toEJSON":MinKey}}"#, #"{"$set":{"toEJSON":{"$minKey":1}}}"#),
        (#"{"toJSON": {"toEJSON":MinKey}}"#, #"{"toJSON":{"toEJSON":{"$minKey":1}}}"#),
        (#"EJSON.__fromServer({"_id":{"toEJSON":{"$minKey":1}}})"#, #"{"_id":{"toEJSON":{"$minKey":1}}}"#)
    ])
    func ownHookMemberIsSent(written: String, sent: String) throws {
        #expect(try evaluate("__ejson(\(written))") == sent)
    }

    @Test("The literal a grid save writes for a stored _id is sent as that _id", arguments: [
        #"{"toEJSON":{"$minKey":1}}"#,
        #"{"shop":"berlin","number":"A-2","x":{"toEJSON":{"$maxKey":1}}}"#
    ])
    func gridLiteralIsSentWhole(stored: String) throws {
        let literal = try MongoExtendedJsonForm.shellValue(MongoDocumentText.Value(parsing: stored), field: "_id")
        #expect(try evaluate("__ejson({\"_id\": \(literal.compactText)})") == "{\"_id\":\(stored)}")
    }

    @Test("A command document is sent with every member the gate read")
    func commandIsSentWhole() throws {
        #expect(try evaluate(#"__ejson({a: {toEJSON: MinKey}, drop: "users"})"#) == #"{"a":{"toEJSON":{"$minKey":1}},"drop":"users"}"#)
    }

    @Test("The shell's value types and boundary keys still serialize themselves")
    func valueTypesSerializeThemselves() throws {
        let sent = try evaluate(#"__ejson({a: ObjectId("507f1f77bcf86cd799439011"), b: MinKey, c: MaxKey(), d: Timestamp(1, 2)})"#)
        #expect(sent == #"{"a":{"$oid":"507f1f77bcf86cd799439011"},"b":{"$minKey":1},"c":{"$maxKey":1},"d":{"$timestamp":{"t":1,"i":2}}}"#)
    }

    @Test("A document with a toEJSON member is shown as a document")
    func ownHookMemberIsShown() throws {
        let classified = try #require(try evaluate(#"__tp_classify({"toEJSON":MinKey})"#))
        let document = #"{"toEJSON":{"$minKey":1}}"#
        #expect(
            try JSONDecoder().decode([String: String].self, from: Data(classified.utf8))
                == ["kind": "document", "json": document, "text": document]
        )
    }
    @Test("Ordered export documents retain number-like and prototype field names")
    func orderedExportDocuments() throws {
        let value = try evaluate(#"__ejson(new Map([["z", null], ["10", "a"], ["2", "b"], ["__proto__", new Map([["10", "x"], ["2", "y"]])]]))"#)
        #expect(value == #"{"z":null,"10":"a","2":"b","__proto__":{"10":"x","2":"y"}}"#)
    }

    @Test("Strict EJSON preserves integral doubles and BSON symbols", arguments: [
        #"{"$numberDouble":"1.0"}"#,
        #"{"$numberDouble":"-0.0"}"#,
        #"{"$numberInt":"42"}"#,
        #"{"$numberLong":"9007199254740993"}"#,
        #"{"$symbol":"symbol"}"#
    ])
    func strictEJSONTypes(canonical: String) throws {
        let quoted = String(decoding: try JSONEncoder().encode(canonical), as: UTF8.self)
        let sent = try #require(try evaluate("__ejson(EJSON.parse(\(quoted), {relaxed:false}))"))
        let original = try #require(try JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? NSDictionary)
        let actual = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? NSDictionary)
        if canonical.contains("$numberDouble") {
            #expect(actual["$numberDouble"] != nil)
            #expect(Double(actual["$numberDouble"] as? String ?? "") == Double(original["$numberDouble"] as? String ?? ""))
        } else {
            #expect(actual == original)
        }
    }

    @Test("Code scopes retain their stored field order")
    func orderedCodeScope() throws {
        #expect(try evaluate(#"__ejson(Code("return x", new Map([["10", NumberLong("5")], ["2", null]])))"#)
            == #"{"$code":"return x","$scope":{"10":{"$numberLong":"5"},"2":null}}"#)
    }

}
