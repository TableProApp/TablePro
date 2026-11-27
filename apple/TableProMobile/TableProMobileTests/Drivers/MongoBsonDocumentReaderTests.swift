import Foundation
@testable import TableProMobile
import TableProPluginKit
import Testing

struct MongoBsonDocumentReaderTests {
    // Every BSON type, the doubles whose spelling is easy to get wrong, and nesting of both kinds.
    static let corpus: [String] = [
        #"{"_id":{"$oid":"64b7f0a1b2c3d4e5f6a7b8c9"},"name":"Ada","n":{"$numberInt":"-2147483648"}}"#,
        #"{"_id":{"$numberLong":"9223372036854775807"},"d":{"$numberDouble":"1.1"},"z":{"$numberDouble":"-0.0"}}"#,
        #"{"_id":"text id","a":{"$numberDouble":"3.0"},"b":{"$numberDouble":"1e300"},"c":{"$numberDouble":"5e-324"}}"#,
        #"{"_id":{"$numberInt":"1"},"nan":{"$numberDouble":"NaN"},"inf":{"$numberDouble":"Infinity"},"ninf":{"$numberDouble":"-Infinity"}}"#,
        #"{"_id":{"$numberInt":"2"},"big":{"$numberDouble":"123456789012345678"},"tiny":{"$numberDouble":"0.1"}}"#,
        #"{"_id":{"$numberInt":"3"},"dec":{"$numberDecimal":"1234.5600"},"neg":{"$numberDecimal":"-Infinity"}}"#,
        #"{"_id":{"$numberInt":"4"},"when":{"$date":{"$numberLong":"-62135596800000"}},"now":{"$date":{"$numberLong":"1700000000123"}}}"#,
        #"{"_id":{"$numberInt":"5"},"t":true,"f":false,"n":null}"#,
        #"{"_id":{"$numberInt":"6"},"b0":{"$binary":{"base64":"AAEC/w==","subType":"00"}},"b80":{"$binary":{"base64":"","subType":"80"}}}"#,
        #"{"_id":{"$numberInt":"16"},"b3":{"$binary":{"base64":"EjRWeJASNFZ4kBI0VniQEg==","subType":"03"}}}"#,
        #"{"_id":{"$numberInt":"17"},"b4":{"$binary":{"base64":"EjRWeJASNFZ4kBI0VniQEg==","subType":"04"}}}"#,
        #"{"_id":{"$numberInt":"7"},"re":{"$regularExpression":{"pattern":"^a.*\"b","options":"mix"}},"code":{"$code":"function () { return 1 }"}}"#,
        #"{"_id":{"$numberInt":"8"},"scope":{"$code":"x","$scope":{"x":{"$numberInt":"1"}}},"sym":{"$symbol":"s"},"ts":{"$timestamp":{"t":4294967295,"i":1}}}"#,
        #"{"_id":{"$numberInt":"9"},"ptr":{"$dbPointer":{"$ref":"c","$id":{"$oid":"64b7f0a1b2c3d4e5f6a7b8c9"}}},"min":{"$minKey":1},"max":{"$maxKey":1},"u":{"$undefined":true}}"#,
        #"{"_id":{"$numberInt":"10"},"s":"line\nbreak \"quoted\" \\ tab\t \u0001 é 漢字 🚀 a\u0000b"}"#,
        #"{"_id":{"a":{"$numberInt":"1"},"b":[{"$numberLong":"2"},"x"]},"nested":{"deep":{"deeper":[[{"$numberInt":"1"}],{"k":null}]}},"empty":{},"none":[]}"#,
        #"{"noId":{"$numberInt":"1"},"$dollar":"top-level dollar name","dotted.name":"x"}"#,
    ]

    private static func bson(_ json: String) throws -> Data {
        try #require(MongoLibbsonCodec().storedBytes(ofJSON: json))
    }

    private static func canonicalText(_ bytes: Data) throws -> String {
        try #require(MongoScriptDocumentBatch.Document.bson(bytes).json)
    }

    // Swift values compared by type and value, with dictionary keys in order so two reads compare equal.
    private static func describe(_ value: Any) -> String {
        switch value {
        case let dictionary as [String: Any]:
            let body = dictionary.sorted { $0.key < $1.key }.map { "\($0.key):\(describe($0.value))" }
            return "{\(body.joined(separator: ","))}"
        case let array as [Any]:
            return "[\(array.map(describe).joined(separator: ","))]"
        case let string as String:
            return "string(\(string.debugDescription))"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool(\(number.boolValue))" }
            let type = String(cString: number.objCType)
            let double = number.doubleValue
            return "number(\(type),\(double.isNaN ? "nan" : String(double.bitPattern)),\(number.int64Value))"
        default:
            return "\(type(of: value))(\(value))"
        }
    }

    @Test("Reading BSON gives what reading its canonical Extended JSON gave, for every type")
    func matchesTheTextRead() throws {
        let reader = MongoBsonDocumentReader()
        for json in Self.corpus {
            let bson = try Self.bson(json)
            let text = try Self.canonicalText(bson)
            let expected = try #require(MongoReadDocument(canonicalJSON: text))
            let read = try #require(reader.read(bson))
            #expect(read.canonical == expected.canonical, "\(text)")
            #expect(read.canonical?.compactText == (try MongoDocumentText(parsing: text)).compactText)
            #expect(Self.describe(read.dictionary) == Self.describe(expected.dictionary), "\(text)")
            #expect(read.identifier == expected.identifier)
            #expect(read.bsonSize == expected.bsonSize)
        }
    }

    @Test("Doubles take libbson's spelling, including the .0 an integral value gets")
    func doubleSpelling() {
        #expect(MongoBsonDocumentReader.canonicalText(of: 3) == "3.0")
        #expect(MongoBsonDocumentReader.canonicalText(of: -0.0) == "-0.0")
        #expect(MongoBsonDocumentReader.canonicalText(of: 1.1) == "1.1000000000000000888")
        #expect(MongoBsonDocumentReader.canonicalText(of: 1e300) == "1.0000000000000000525e+300")
        #expect(MongoBsonDocumentReader.canonicalText(of: .nan) == "NaN")
        #expect(MongoBsonDocumentReader.canonicalText(of: -.infinity) == "-Infinity")
    }

    @Test("A repeated field name leaves the document without a canonical tree, as the strict text read refused it")
    func repeatedFieldHasNoTree() throws {
        let bson = try Self.bson(#"{"_id":{"$numberInt":"1"},"a":{"$numberInt":"1"},"a":"again"}"#)
        let read = try #require(MongoBsonDocumentReader().read(bson))
        #expect(read.canonical == nil)
        #expect(read.identifier == #"{"$numberInt":"1"}"#)
        #expect(read.dictionary["a"] != nil)
    }

    @Test("A code scope that repeats a name keeps its row, without a canonical tree")
    func repeatedScopeNameKeepsTheRow() throws {
        let bson = try Self.bson(#"{"_id":{"$numberInt":"1"},"f":{"$code":"x","$scope":{"x":{"$numberInt":"1"},"x":"again"}}}"#)
        let read = try #require(MongoBsonDocumentReader().read(bson))
        #expect(read.canonical == nil)
        #expect(read.identifier == #"{"$numberInt":"1"}"#)
        #expect(read.dictionary["f"] != nil)
    }

    @Test("An _id holding such a code scope gives no locator, never one without that part")
    func repeatedScopeNameInTheIdGivesNoLocator() throws {
        let bson = try Self.bson(#"{"_id":{"f":{"$code":"x","$scope":{"x":{"$numberInt":"1"},"x":"again"}},"k":{"$numberInt":"1"}}}"#)
        let read = try #require(MongoBsonDocumentReader().read(bson))
        #expect(read.canonical == nil)
        #expect(read.identifier == nil)
        #expect(read.dictionary["_id"] != nil)
    }

    @Test("Two spellings of one character are two field names, as BSON compares names by their bytes")
    func namesCompareAsBytes() throws {
        let bson = try Self.bson(#"{"_id":{"$numberInt":"1"},"nested":{"é":"precomposed","é":"combining"}}"#)
        let read = try #require(MongoBsonDocumentReader().read(bson))
        guard case .object(let members)? = read.canonical?.value(of: "nested") else {
            Issue.record("the nested document has no canonical tree")
            return
        }
        #expect(members.count == 2)
    }

    @Test("A cursor batch keeps the stored bytes, and JavaScript still gets canonical Extended JSON")
    func batchKeepsBytes() throws {
        let bytes = try Self.bson(Self.corpus[0])
        let batch = MongoScriptDocumentBatch(documents: [.bson(bytes)], isTruncated: false)
        #expect(batch.json == [try Self.canonicalText(bytes)])
        let read = batch.readDocuments
        #expect(read.bsonSizes == [bytes.count])
        #expect(read.identifiers == [#"{"$oid":"64b7f0a1b2c3d4e5f6a7b8c9"}"#])
        let exported = try MongoExportDocument.read(read, representation: .unspecified)
        #expect(exported.first?.canonicalJSON == (try MongoDocumentText(parsing: batch.json[0])).compactText)
        #expect(exported.first?.bsonSizeUpperBound == bytes.count)
    }
}
