//
//  MongoDBNestedValueWriteTests.swift
//  TableProTests
//

import Foundation
import JavaScriptCore
import TableProNumberFormatting
import TableProPluginKit
import Testing

struct MongoDBNestedValueWriteTests {
    private static let address = #"{"zip":"100","city":"HN","verifiedAt":{"$date":"2024-05-01T10:00:00.123Z"},"#
        + #""ownerId":{"$oid":"65a1b2c3d4e5f60718293a4b"},"n":{"$numberLong":"5"},"d":3.0}"#

    private func update(
        _ column: String,
        from oldText: String,
        to newText: String,
        kind: BsonValueKind = .document
    ) throws -> String {
        try update(column, from: .text(oldText), to: newText, held: [kind], majority: kind)
    }

    /// An edit in a field whose documents held `held`, or were never read when it is nil, typed by
    /// its `majority` kind.
    private func update(
        _ column: String,
        from oldValue: PluginCellValue,
        to newText: String,
        held: Set<BsonValueKind>?,
        majority: BsonValueKind = .document
    ) throws -> String {
        let gen = MongoDBStatementGenerator(
            collectionName: "people",
            columns: ["_id", column],
            columnKinds: [column: majority],
            fieldKinds: MongoDBFieldKinds(held.map { [column: $0] } ?? [:])
        )
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: column, oldValue: oldValue, newValue: .text(newText))],
            originalRow: [.text("1"), oldValue]
        )
        let writes = try gen.generateRowWrites(from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: [])
        return try #require(writes.first?.statement)
    }

    private func insert(_ column: String, _ text: String, held: Set<BsonValueKind>? = nil, typed: Bool = false) throws -> String {
        let gen = MongoDBStatementGenerator(
            collectionName: "people",
            columns: ["_id", column],
            fieldKinds: MongoDBFieldKinds(held.map { [column: $0] } ?? [:])
        )
        let filledIn = typed ? [(columnIndex: 1, columnName: column, oldValue: PluginCellValue.null, newValue: PluginCellValue.text(text))] : []
        let writes = try gen.generateRowWrites(
            from: [PluginRowChange(rowIndex: 0, type: .insert, cellChanges: filledIn, originalRow: nil)],
            insertedRowData: [0: [nil, .text(text)]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        return try #require(writes.first?.statement)
    }

    // MARK: - Display

    @Test("A nested document shows its stored order and its BSON types")
    func displayKeepsOrderAndTypes() throws {
        let canonical = #"{"_id":{"$numberInt":"1"},"address":{"zip":"100","city":"HN","#
            + #""verifiedAt":{"$date":{"$numberLong":"1714557600123"}},"ownerId":{"$oid":"65a1b2c3d4e5f60718293a4b"},"#
            + #""amount":{"$numberDecimal":"1847.270000000000000000000000001"},"n":{"$numberLong":"5"},"#
            + #""d":{"$numberDouble":"3.0"},"i":{"$numberInt":"7"},"bin":{"$binary":{"base64":"AAECAw==","subType":"05"}}}}"#
        let document: [String: Any] = ["_id": Int32(1), "address": ["zip": "100"]]

        let rows = BsonDocumentFlattener.flatten(
            documents: [document], columns: ["_id", "address"], kinds: [.int32, .document],
            representation: .unspecified, storedTexts: [canonical]
        )

        let shown = #"{"zip":"100","city":"HN","verifiedAt":{"$date":"2024-05-01T10:00:00.123Z"},"#
            + #""ownerId":{"$oid":"65a1b2c3d4e5f60718293a4b"},"amount":{"$numberDecimal":"1847.270000000000000000000000001"},"#
            + #""n":{"$numberLong":"5"},"d":3.0,"i":7,"bin":{"$binary":{"base64":"AAECAw==","subType":"05"}}}"#
        #expect(rows[0][1] == .text(shown))
    }

    @Test("Doubles show their shortest spelling, and values outside the relaxed form keep their wrappers")
    func displayKeepsWrappersItCannotRelax() {
        let canonical = MongoDocumentText.Value.object([
            .init(key: "tenth", value: .object([.init(key: "$numberDouble", value: .string("0.10000000000000000555"))])),
            .init(key: "e", value: .object([.init(key: "$numberDouble", value: .string("1e+20"))])),
            .init(key: "nan", value: .object([.init(key: "$numberDouble", value: .string("NaN"))])),
            .init(key: "old", value: .object([.init(key: "$date", value: .object([.init(key: "$numberLong", value: .string("-1"))]))]))
        ])

        let shown = MongoExtendedJsonForm.display(canonical).compactText

        #expect(shown == #"{"tenth":0.1,"e":1e+20,"nan":{"$numberDouble":"NaN"},"old":{"$date":{"$numberLong":"-1"}}}"#)
    }

    @Test("A cell without stored text keeps the older rendering")
    func displayWithoutStoredTextIsUnchanged() {
        let rows = BsonDocumentFlattener.flatten(
            documents: [["tags": ["b", "a"]]], columns: ["tags"], kinds: [.array], representation: .unspecified
        )

        #expect(rows[0][0] == .text(#"["b","a"]"#))
    }

    // MARK: - Updates

    @Test("Editing one nested key writes only that path")
    func singleLeafEdit() throws {
        let edited = Self.address.replacingOccurrences(of: #""city":"HN""#, with: #""city":"HN2""#)

        let statement = try update("address", from: Self.address, to: edited)

        #expect(statement == #"db.people.updateOne({"_id": 1}, {"$set": {"address.city": "HN2"}})"#)
    }

    @Test("Removing a nested key writes $unset on its path")
    func nestedRemoval() throws {
        let edited = Self.address.replacingOccurrences(of: #""zip":"100","#, with: "")

        let statement = try update("address", from: Self.address, to: edited)

        #expect(statement == #"db.people.updateOne({"_id": 1}, {"$unset": {"address.zip": ""}})"#)
    }

    @Test("One key added at the end is set on its path")
    func appendedKeyIsAPath() throws {
        let edited = String(Self.address.dropLast()) + #","extra":{"$numberLong":"9"}}"#

        let statement = try update("address", from: Self.address, to: edited)

        #expect(statement == #"db.people.updateOne({"_id": 1}, {"$set": {"address.extra": {"$numberLong":"9"}}})"#)
    }

    @Test("Keys the server would append in its own order are written as the whole object")
    func reorderedAdditionsAreWrittenWhole() throws {
        let twoNew = try update("meta", from: #"{"a":1}"#, to: #"{"a":1,"z":2,"b":3}"#)
        let inserted = try update("meta", from: #"{"a":1,"c":3}"#, to: #"{"a":1,"b":2,"c":3}"#)
        let moved = try update("meta", from: #"{"a":1,"b":2}"#, to: #"{"b":2,"a":1}"#)

        #expect(twoNew.contains(#"{"$set": {"meta": {"a":1,"z":2,"b":3}}}"#))
        #expect(inserted.contains(#"{"$set": {"meta": {"a":1,"b":2,"c":3}}}"#))
        #expect(moved.contains(#"{"$set": {"meta": {"b":2,"a":1}}}"#))
    }

    @Test("A same-length array edit writes the index, a length change writes the array with its wrappers")
    func arrayEdits() throws {
        let tags = #"[{"$oid":"65a1b2c3d4e5f60718293a4b"},"b",3.0]"#

        let index = try update("tags", from: tags, to: tags.replacingOccurrences(of: #""b""#, with: #""B""#), kind: .array)
        let grown = try update("tags", from: tags, to: String(tags.dropLast()) + #","c"]"#, kind: .array)

        #expect(index == #"db.people.updateOne({"_id": 1}, {"$set": {"tags.1": "B"}})"#)
        #expect(grown == #"db.people.updateOne({"_id": 1}, {"$set": {"tags": [{"$oid":"65a1b2c3d4e5f60718293a4b"},"b",{"$numberDouble":"3.0"},"c"]}})"#)
    }

    @Test("A changed nested key that holds a dot is written as the whole enclosing value")
    func unaddressableNestedKeyEscalates() throws {
        let statement = try update("meta", from: #"{"a.b":1,"c":2}"#, to: #"{"a.b":5,"c":2}"#)

        #expect(statement.contains(#"{"$set": {"meta": {"a.b":5,"c":2}}}"#))
    }

    @Test("A value whose type changed is written whole at its path")
    func typeChangeWritesTheValue() throws {
        let statement = try update("meta", from: #"{"a":{"x":1}}"#, to: #"{"a":[1]}"#)

        #expect(statement.contains(#"{"$set": {"meta.a": [1]}}"#))
    }

    @Test("An edit that only reformats the text still writes the value, so the row is not left unwritten")
    func reformatOnlyWritesTheWholeValue() throws {
        let statement = try update("meta", from: #"{"a":1}"#, to: "{\n  \"a\": 1\n}")

        #expect(statement.contains(#"{"$set": {"meta": {"a":1}}}"#))
    }

    @Test("Text that is not JSON in a document column is refused")
    func unreadableJsonIsRefused() {
        #expect(throws: MongoDBWriteRefusal.unreadableJSON(field: "meta").refusal(ofRow: 0)) {
            try update("meta", from: #"{"a":1}"#, to: #"{"a":}"#)
        }
    }

    @Test("A complete value typed over one shortened for display replaces the field whole")
    func truncatedOldValueIsReplacedWhole() throws {
        let stored = #"{"big":""# + String(repeating: "x", count: 12_000) + #"","keep":1}"#
        let shown = JSONTruncation.truncate(stored, maxLength: BsonDocumentFlattener.maxNestedJsonLength)

        let statement = try update("meta", from: shown, to: #"{"a":1,"d":3.0}"#)

        #expect(statement == #"db.people.updateOne({"_id": 1}, {"$set": {"meta": {"a":1,"d":{"$numberDouble":"3.0"}}}})"#)
    }

    @Test("An edit that keeps the shortened text is still refused")
    func truncatedEditIsRefused() {
        let stored = #"{"keep":1,"big":""# + String(repeating: "x", count: 12_000) + #""}"#
        let shown = JSONTruncation.truncate(stored, maxLength: BsonDocumentFlattener.maxNestedJsonLength)

        #expect(throws: MongoDBWriteRefusal.truncatedValue(field: "meta").refusal(ofRow: 0)) {
            try update("meta", from: shown, to: shown.replacingOccurrences(of: #""keep":1"#, with: #""keep":2"#))
        }
    }

    // MARK: - A field that held documents and strings

    /// Measured on 7.0.43: in a field where most rows hold documents, `{"$set": {"f.a": 2}}` on the
    /// row holding the string `{"a":1}` fails with "[28] Cannot create field 'a' in element".
    @Test("A string that reads as JSON, in a field of mostly documents, is never diffed into a path")
    func jsonLookingStringInAMixedFieldIsRefused() {
        #expect(throws: MongoDBWriteRefusal.documentOrText(field: "f").refusal(ofRow: 0)) {
            try update("f", from: .text(#"{"a":1}"#), to: #"{"a":2}"#, held: [.document, .string])
        }
    }

    @Test("A document in a field that also held strings is written whole or not at all, never as a path")
    func documentInAMixedFieldIsNeverAPath() throws {
        #expect(throws: MongoDBWriteRefusal.documentOrText(field: "f").refusal(ofRow: 0)) {
            try update("f", from: .text(#"{"a":1,"b":2}"#), to: #"{"a":5,"b":2}"#, held: [.document, .string])
        }
        #expect(throws: MongoDBWriteRefusal.documentOrText(field: "f").refusal(ofRow: 0)) {
            try update("f", from: .text("[1,2]"), to: "[1,3]", held: [.array, .string], majority: .array)
        }
    }

    @Test("Text that is not JSON typed over a string that is not JSON either stays a string")
    func malformedStringInAMixedFieldStaysAString() throws {
        let statement = try update("f", from: .text("{abc"), to: "{abcd", held: [.document, .string])

        #expect(statement == #"db.people.updateOne({"_id": 1}, {"$set": {"f": "{abcd"}})"#)
    }

    @Test("JSON typed over a string in a field that also held documents is refused, since it could be either")
    func jsonOverAStringInAMixedFieldIsRefused() {
        for old: PluginCellValue in [.text("{abc"), .text("plain"), .null] {
            #expect(throws: MongoDBWriteRefusal.documentOrText(field: "f").refusal(ofRow: 0), "\(old)") {
                try update("f", from: old, to: #"{"x":1}"#, held: [.document, .string])
            }
        }
    }

    @Test("Text that is not JSON typed over a document in a mixed field is refused, not stored as a string")
    func malformedTextOverAPossibleDocumentIsRefused() {
        #expect(throws: MongoDBWriteRefusal.documentOrText(field: "f").refusal(ofRow: 0)) {
            try update("f", from: .text(#"{"a":1}"#), to: #"{"a":"#, held: [.document, .string])
        }
    }

    @Test("A document and an array in one field are told apart by their text, so each is still diffed")
    func documentsAndArraysAreToldApart() throws {
        let document = try update("f", from: .text(#"{"a":1,"b":2}"#), to: #"{"a":5,"b":2}"#, held: [.document, .array])
        let array = try update("f", from: .text("[1,2]"), to: "[1,3]", held: [.document, .array])

        #expect(document == #"db.people.updateOne({"_id": 1}, {"$set": {"f.a": 5}})"#)
        #expect(array == #"db.people.updateOne({"_id": 1}, {"$set": {"f.1": 3}})"#)
    }

    @Test("A field whose documents were never read is never diffed")
    func unreadFieldIsNeverAPath() {
        #expect(throws: MongoDBWriteRefusal.documentOrText(field: "f").refusal(ofRow: 0)) {
            try update("f", from: .text(#"{"a":1}"#), to: #"{"a":2}"#, held: nil)
        }
    }

    @Test("A copied value that reads as JSON in a mixed field is refused, and one that does not is a string")
    func copiedValuesInAMixedField() throws {
        #expect(throws: MongoDBWriteRefusal.documentOrText(field: "f").refusal(ofRow: 0)) {
            try insert("f", #"{"a":1}"#, held: [.document, .string])
        }
        #expect(throws: MongoDBWriteRefusal.documentOrText(field: "f").refusal(ofRow: 0)) {
            try insert("f", "{abc", held: [.document, .string], typed: true)
        }
        let copied = try insert("f", "{abc", held: [.document, .string])
        #expect(copied == #"db.people.insertOne({"f": "{abc"})"#)
    }

    @Test("Text that reads as JSON in a field that only held strings stays a string when copied, restored or typed over")
    func stringOnlyFieldKeepsJSONShapedText() throws {
        let copied = try insert("f", #"{"a":1}"#, held: [.string])
        let edited = try update("f", from: .text("plain"), to: "[1,2]", held: [.string], majority: .string)
        let typed = try insert("f", #"{"a":1}"#, held: [.string], typed: true)
        let strings = MongoDBStatementGenerator(
            collectionName: "people", columns: ["_id", "f"], fieldKinds: MongoDBFieldKinds(["f": [.string]])
        )
        let restored = try #require(strings.generateRestore(rows: [["507f1f77bcf86cd799439011", #"{"a":1}"#]])?.first)

        #expect(copied == #"db.people.insertOne({"f": "{\"a\":1}"})"#)
        #expect(edited == #"db.people.updateOne({"_id": 1}, {"$set": {"f": "[1,2]"}})"#)
        #expect(typed.contains(#""f": {"a":1}"#))
        #expect(restored.statement.contains(#""f": "{\"a\":1}""#))
    }

    @Test("A restore that reads as JSON in a field never read is refused, and one that does not is a string")
    func restoreIntoAnUnreadField() throws {
        let relaunched = MongoDBStatementGenerator(collectionName: "people", columns: ["_id", "f"])
        let documents = MongoDBStatementGenerator(
            collectionName: "people", columns: ["_id", "f"], fieldKinds: MongoDBFieldKinds(["f": [.document]])
        )

        #expect(relaunched.generateRestore(rows: [["507f1f77bcf86cd799439011", #"{"a":1}"#]]) == nil)
        let text = try #require(relaunched.generateRestore(rows: [["507f1f77bcf86cd799439011", "{abc"]])?.first)
        #expect(text.statement.contains(#""f": "{abc""#))
        let document = try #require(documents.generateRestore(rows: [["507f1f77bcf86cd799439011", #"{"a":1}"#]])?.first)
        #expect(document.statement.contains(#""f": {"a":1}"#))
    }

    // MARK: - Recording what each field held

    @Test("Each field records every kind it held, nulls aside")
    func fieldKindsRecordEveryKind() {
        let recorded = MongoDBFieldKinds.recording(
            [["f": ["a": 1], "g": "x", "n": NSNull()], ["f": "{\"a\":1}", "g": "y"], ["f": [1]]],
            representation: .unspecified
        )

        #expect(recorded.kinds(of: "f") == [.document, .string, .array])
        #expect(recorded.kinds(of: "g") == [.string])
        #expect(recorded.kinds(of: "n") == nil)
        #expect(recorded.kinds(of: "missing") == nil)
    }

    @Test("A later page adds to what a field held, so a string read earlier is not forgotten")
    func fieldKindsMergeRatherThanReplace() {
        let merged = MongoDBFieldKinds(["f": [.string]]).merging(MongoDBFieldKinds(["f": [.document], "g": [.int32]]))

        #expect(merged.kinds(of: "f") == [.string, .document])
        #expect(merged.kinds(of: "g") == [.int32])
    }

    @Test("Past the field limit no new field is recorded, and an unrecorded field reads as unknown")
    func fieldKindsStopAtTheLimit() {
        let full = MongoDBFieldKinds(Dictionary(uniqueKeysWithValues: (0 ..< MongoDBFieldKinds.fieldLimit).map { ("k\($0)", Set([BsonValueKind.string])) }))

        let merged = full.merging(MongoDBFieldKinds(["k0": [.document], "new": [.document]]))

        #expect(merged.kinds(of: "k0") == [.string, .document])
        #expect(merged.kinds(of: "new") == nil)
    }

    // MARK: - Whole values

    @Test("A whole value keeps a whole-number double as a double and a 64-bit integer as one")
    func wholeValueKeepsNumberTypes() throws {
        let statement = try insert("meta", #"{"d":3.0,"z":-0.0,"e":1e3,"f":1.5,"n":{"$numberLong":"5"},"big":9007199254740993,"i":7}"#)

        let written = #""meta": {"d":{"$numberDouble":"3.0"},"z":{"$numberDouble":"-0.0"},"e":{"$numberDouble":"1e3"},"#
            + #""f":1.5,"n":{"$numberLong":"5"},"big":{"$numberLong":"9007199254740993"},"i":7}"#
        #expect(statement.contains(written))
    }

    @Test("An integer past 64 bits inside a value is refused")
    func integerPastInt64IsRefused() {
        #expect(throws: MongoDBWriteRefusal.integerTooLarge(field: "meta").refusal(ofRow: 0)) {
            try insert("meta", #"{"n":99999999999999999999}"#)
        }
    }

    @Test("A key JavaScript would move or drop is refused, and number-like keys already first are written")
    func shellKeyOrder() throws {
        #expect(throws: MongoDBWriteRefusal.reorderedByTheShell(field: "meta").refusal(ofRow: 0)) {
            try insert("meta", #"{"zip":"1","2":"two"}"#)
        }
        #expect(throws: MongoDBWriteRefusal.reorderedByTheShell(field: "meta").refusal(ofRow: 0)) {
            try insert("meta", #"{"a":{"__proto__":1}}"#)
        }
        #expect(throws: MongoDBWriteRefusal.reorderedByTheShell(field: "meta").refusal(ofRow: 0)) {
            try insert("meta", #"{"10":1,"9":2}"#)
        }
        let ordered = try insert("meta", #"{"2":"two","10":"ten","zip":"1"}"#)
        #expect(ordered.contains(#""meta": {"2":"two","10":"ten","zip":"1"}"#))
    }

    @Test("An object that opens with a wrapper key and holds other members is a document, so its keys are checked")
    func wrapperShapedDocumentIsCheckedAsADocument() throws {
        typealias Member = MongoDocumentText.Member
        let hex = MongoDocumentText.Value.string("507f1f77bcf86cd799439011")

        #expect(throws: MongoDBWriteRefusal.reorderedByTheShell(field: "meta").refusal(ofRow: 0)) {
            try insert("meta", #"{"$oid":"x","__proto__":1}"#)
        }
        #expect(MongoExtendedJsonForm.isWrapper([Member(key: "$oid", value: hex)]))
        #expect(!MongoExtendedJsonForm.isWrapper([Member(key: "$oid", value: hex), Member(key: "note", value: hex)]))
        #expect(MongoExtendedJsonForm.isWrapper([Member(key: "$binary", value: hex), Member(key: "$type", value: hex)]))
        #expect(MongoExtendedJsonForm.isWrapper([Member(key: "$regex", value: hex), Member(key: "$options", value: hex)]))
        #expect(!MongoExtendedJsonForm.isWrapper([
            Member(key: "$regex", value: hex), Member(key: "$options", value: hex), Member(key: "$options", value: hex)
        ]))
    }

    @Test("Only array-index keys up to 4294967294 are moved, so a larger number-like key is written where it is")
    func shellKeyOrderStopsAtTheArrayIndexRange() throws {
        #expect(throws: MongoDBWriteRefusal.reorderedByTheShell(field: "meta").refusal(ofRow: 0)) {
            try insert("meta", #"{"name":"a","4294967294":"b"}"#)
        }
        let past = try insert("meta", #"{"name":"a","4294967295":"b","99999999999":"c"}"#)
        #expect(past.contains(#""meta": {"name":"a","4294967295":"b","99999999999":"c"}"#))
    }

    @Test("A timestamp and the boundary keys are written as the shell's own values, which keep their numbers bare")
    func numericWrappersUseTheShellsValues() throws {
        let statement = try insert(
            "meta",
            #"{"ts":{"$timestamp":{"t":1700000000,"i":7}},"lo":{"$minKey":1},"hi":{"$maxKey":1},"#
                + #""arr":[{"$timestamp":{"i":2,"t":4294967295}},{"$maxKey":1}]}"#
        )

        #expect(statement.contains(
            #""meta": {"ts":Timestamp(1700000000, 7),"lo":MinKey,"hi":MaxKey,"arr":[Timestamp(4294967295, 2),MaxKey]}"#
        ))
    }

    @Test("A code scope is spelled as a document, so its numbers keep their types and its keys their order")
    func codeScopeIsSpelledAsADocument() throws {
        let statement = try insert("meta", #"{"c":{"$code":"f","$scope":{"n":3.0,"i":{"$numberInt":"1"}}}}"#)

        #expect(statement.contains(#""meta": {"c":{"$code":"f","$scope":{"n":{"$numberDouble":"3.0"},"i":{"$numberInt":"1"}}}}"#))
        #expect(throws: MongoDBWriteRefusal.reorderedByTheShell(field: "meta").refusal(ofRow: 0)) {
            try insert("meta", #"{"c":{"$code":"f","$scope":{"a":1,"2":2}}}"#)
        }
    }

    // MARK: - Through the shell

    private static let everyWrapper = #"{"oid":{"$oid":"65a1b2c3d4e5f60718293a4b"},"sym":{"$symbol":"s"},"#
        + #""i":{"$numberInt":"7"},"l":{"$numberLong":"5"},"d":{"$numberDouble":"3.0"},"f":{"$numberDouble":"1.5"},"#
        + #""dec":{"$numberDecimal":"1.5"},"bin":{"$binary":{"base64":"AAECAw==","subType":"05"}},"#
        + #""code":{"$code":"f"},"scoped":{"$code":"f","$scope":{"x":{"$numberInt":"1"}}},"#
        + #""ts":{"$timestamp":{"t":1700000000,"i":7}},"re":{"$regularExpression":{"pattern":"^a","options":"i"}},"#
        + #""ptr":{"$dbPointer":{"$ref":"c","$id":{"$oid":"65a1b2c3d4e5f60718293a4b"}}},"#
        + #""old":{"$date":{"$numberLong":"-1"}},"lo":{"$minKey":1},"hi":{"$maxKey":1},"u":{"$undefined":true},"#
        + #""arr":[{"$timestamp":{"t":1,"i":2}},{"$minKey":1}],"#
        + #""big":{"name":{"$numberInt":"1"},"4294967295":{"$numberInt":"2"}}}"#

    private func shownCell(_ canonical: String) throws -> PluginCellValue {
        let rows = BsonDocumentFlattener.flatten(
            documents: [["_id": Int32(1), "m": ["x": 1]]], columns: ["_id", "m"], kinds: [.int32, .document],
            representation: .unspecified, storedTexts: [#"{"_id":{"$numberInt":"1"},"m":"# + canonical + "}"]
        )
        return try #require(rows.first?[1])
    }

    private func evaluate(_ statement: String, reply: String) throws -> MongoScriptPreludeTests.RecordingHost {
        let host = MongoScriptPreludeTests.RecordingHost()
        host.replies = [reply]
        let context = try MongoScriptContext.make(execute: { host.handle($0) }, emit: { host.record(printed: $0) })
        context.evaluateScript(statement)
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return host
    }

    @Test("A duplicated row hands the shell every nested BSON type as the Extended JSON it was read as")
    func duplicateRoundTripsThroughTheShell() throws {
        let cell = try shownCell(Self.everyWrapper)
        let gen = MongoDBStatementGenerator(collectionName: "people", columns: ["_id", "m"], columnKinds: ["m": .document])
        let writes = try gen.generateRowWrites(
            from: [PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)],
            insertedRowData: [0: ["__DEFAULT__", cell]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )
        let statement = try #require(writes.first?.statement)

        let host = try evaluate(statement, reply: #"{"insertedIds": [{"$oid": "507f1f77bcf86cd799439011"}], "insertedCount": 1}"#)

        #expect(host.requests(op: "insertOne").first?["document"] as? String == #"{"m":"# + Self.everyWrapper + "}")
    }

    @Test("A nested value written whole hands the shell its BSON types unchanged")
    func wholeRewriteRoundTripsThroughTheShell() throws {
        let cell = try shownCell(Self.everyWrapper)
        let shown = try #require(cell.asText)
        let grown = String(shown.dropLast()) + #","extra":1,"extra2":2}"#

        let statement = try update("m", from: shown, to: grown)
        let host = try evaluate(statement, reply: #"{"n": 1, "nModified": 1}"#)

        let written = String(Self.everyWrapper.dropLast()) + #","extra":{"$numberInt":"1"},"extra2":{"$numberInt":"2"}}"#
        #expect(host.requests(op: "update").first?["update"] as? String == #"{"$set":{"m":"# + written + "}}")
    }

    @Test("A duplicated row keeps a nested ObjectId and date")
    func duplicateKeepsNestedWrappers() throws {
        let statement = try insert("address", Self.address)

        #expect(statement.contains(#""ownerId":{"$oid":"65a1b2c3d4e5f60718293a4b"}"#))
        #expect(statement.contains(#""verifiedAt":{"$date":"2024-05-01T10:00:00.123Z"}"#))
        #expect(statement.contains(#""d":{"$numberDouble":"3.0"}"#))
    }

    @Test("A document _id is matched in the order it is stored")
    func documentIdKeepsItsOrder() throws {
        let gen = MongoDBStatementGenerator(collectionName: "people", columns: ["_id", "name"], identityKind: .document)
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: "a", newValue: "b")],
            originalRow: [.text(#"{"z":1,"a":{"$numberLong":"2"}}"#), "a"]
        )

        let writes = try gen.generateRowWrites(from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: [])

        #expect(writes.first?.statement == #"db.people.updateOne({"_id": {"z":1,"a":{"$numberLong":"2"}}}, {"$set": {"name": "b"}})"#)
    }

    // MARK: - Parsing one value

    @Test("One value parses with the document reader's strictness, top-level $ names included")
    func valueParsing() throws {
        #expect(try MongoDocumentText.Value(parsing: #"{"$price":1}"#) == .object([.init(key: "$price", value: .number("1"))]))
        #expect(try MongoDocumentText.Value(parsing: " [1, \"a\"] ") == .array([.number("1"), .string("a")]))
        #expect(throws: MongoDocumentText.Refusal.trailingContent) { try MongoDocumentText.Value(parsing: "[1] [2]") }
        #expect(throws: MongoDocumentText.Refusal.duplicateField("a")) { try MongoDocumentText.Value(parsing: #"{"a":1,"a":2}"#) }
    }
}
