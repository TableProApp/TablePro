//
//  MongoDocumentGuardTests.swift
//  TableProTests
//
//  What the server answers for these filters is checked against a live server by
//  scripts/check-mongodb-document-guard.sh; these pin the text the driver builds.
//

import Foundation
import Testing

struct MongoDocumentGuardTests {
    private func filter(_ canonical: String) throws -> String {
        try MongoDocumentGuard.filter(for: MongoDocumentText(parsing: canonical))
    }

    /// The `$literal` the type signature is compared with, which is the last one in the filter.
    private func expectedSignature(_ canonical: String) throws -> String {
        let text = try filter(canonical)
        let marker = #"{"$literal":"#
        let start = try #require(text.range(of: marker, options: .backwards)).upperBound
        return String(text[start...].dropLast(6))
    }

    @Test("A flat document's filter, in full")
    func goldenFilter() throws {
        let children = #"{"$cond":[{"$isArray":"$$ROOT"},"$$ROOT",{"$map":{"input":{"$objectToArray":"#
            + #"{"$cond":[{"$eq":[{"$type":"$$ROOT"},"object"]},"$$ROOT",{}]}},"in":"$$this.v"}}]}"#
        let leaf = #"{"$cond":[{"$or":[{"$eq":[{"$type":"$$this"},"decimal"]},{"$and":[{"$eq":[{"$type":"$$this"},"#
            + #""double"]},{"$eq":["$$this",0]}]}]},[{"$type":"$$this"},{"$convert":{"input":"$$this","to":"string","#
            + #""onError":"","onNull":""}}],{"$type":"$$this"}]}"#
        let signature = #"{"$map":{"input":\#(children),"in":\#(leaf)}}"#
        let document = #"{"_id":{"$numberInt":"1"},"n":{"$numberInt":"5"}}"#
        let expected = #"{"_id":{"$numberInt":"1"},"$expr":{"$and":[{"$eq":["$$ROOT",{"$literal":\#(document)}]},"#
            + #"{"$eq":[\#(signature),{"$literal":["int","int"]}]}]}}"#
        #expect(try filter(#"{ "_id" : { "$numberInt" : "1" }, "n" : { "$numberInt" : "5" } }"#) == expected)
    }

    @Test("The whole-document comparison comes first, so the signature is only asked about a document that matched")
    func wholeDocumentFirst() throws {
        let text = try filter(#"{"_id":{"$numberInt":"1"}}"#)
        let root = try #require(text.range(of: #""$and":[{"$eq":["$$ROOT",{"$literal":"#))
        let map = try #require(text.range(of: #""$map""#))
        #expect(root.lowerBound < map.lowerBound)
    }

    @Test("Every type marker is compared by its $type name")
    func typeNames() throws {
        let cases: [(String, String)] = [
            (#"{"$oid":"65f0a1b2c3d4e5f607182930"}"#, #""objectId""#),
            (#"{"$numberInt":"5"}"#, #""int""#),
            (#"{"$numberLong":"5"}"#, #""long""#),
            (#"{"$numberDouble":"5.0"}"#, #""double""#),
            (#"{"$date":{"$numberLong":"0"}}"#, #""date""#),
            (#"{"$binary":{"base64":"AQID","subType":"00"}}"#, #""binData""#),
            (#"{"$regularExpression":{"pattern":"a","options":""}}"#, #""regex""#),
            (#"{"$timestamp":{"t":5,"i":1}}"#, #""timestamp""#),
            (#"{"$minKey":1}"#, #""minKey""#),
            (#"{"$maxKey":1}"#, #""maxKey""#),
            (#"{"$symbol":"s"}"#, #""symbol""#),
            (#"{"$undefined":true}"#, #""undefined""#),
            (#"{"$dbPointer":{"$ref":"c","$id":{"$oid":"65f0a1b2c3d4e5f607182930"}}}"#, #""dbPointer""#),
            (#"{"$code":"x"}"#, #""javascript""#),
            (#""text""#, #""string""#),
            ("true", #""bool""#),
            ("null", #""null""#)
        ]
        for (value, type) in cases {
            let signature = try expectedSignature(#"{"_id":{"$numberInt":"1"},"v":\#(value)}"#)
            #expect(signature == #"["int",\#(type)]"#, "\(value)")
        }
    }

    @Test("A decimal carries its text and a zero double its sign, and nothing else does")
    func textWhereEqualityIsLenient() throws {
        let signature = try expectedSignature(
            #"{"_id":{"$numberInt":"1"},"a":{"$numberDecimal":"1.00"},"b":{"$numberDouble":"-0.0"},"#
                + #""c":{"$numberDouble":"0.0"},"d":{"$numberDouble":"2.5"},"e":{"$numberDecimal":"Infinity"}}"#
        )
        #expect(signature == #"["int",["decimal","1.00"],["double","-0"],["double","0"],"double",["decimal","Infinity"]]"#)
    }

    /// The server's `$eq` answers yes for two NaNs whatever their bits, and `$type` and `$convert`
    /// cannot tell them apart either, so no filter can notice one NaN replaced by another.
    @Test("A NaN anywhere in the document is refused, double or decimal, at any depth")
    func notANumberIsRefused() {
        let documents = [
            #"{"_id":{"$numberInt":"1"},"n":{"$numberDouble":"NaN"}}"#,
            #"{"_id":{"$numberInt":"1"},"n":{"$numberDecimal":"NaN"}}"#,
            #"{"_id":{"$numberDouble":"NaN"}}"#,
            #"{"_id":{"$numberInt":"1"},"o":{"a":[{"$numberInt":"1"},{"$numberDouble":"NaN"}]}}"#
        ]
        for document in documents {
            #expect(throws: MongoDocumentGuard.Refusal.notANumber, "\(document)") {
                try filter(document)
            }
        }
    }

    /// A scope is compared the way a query compares, so `1` and `NumberLong(1)` inside it are equal,
    /// and no expression can open it to compare its types instead.
    @Test("JavaScript code with a scope is refused anywhere, even with an empty scope")
    func codeWithScopeIsRefused() {
        let documents = [
            #"{"_id":{"$numberInt":"1"},"c":{"$code":"x","$scope":{"a":{"$numberInt":"1"}}}}"#,
            #"{"_id":{"$numberInt":"1"},"c":{"$code":"x","$scope":{}}}"#,
            #"{"_id":{"$numberInt":"1"},"a":[{"o":{"$code":"x","$scope":{}}}]}"#
        ]
        for document in documents {
            #expect(throws: MongoDocumentGuard.Refusal.codeWithScope, "\(document)") {
                try filter(document)
            }
        }
    }

    @Test("Code without a scope, and a field named NaN, are guarded as usual")
    func nearMissesAreGuarded() throws {
        let signature = try expectedSignature(
            #"{"_id":{"$numberInt":"1"},"c":{"$code":"x"},"NaN":"NaN","d":{"$numberDouble":"Infinity"}}"#
        )
        #expect(signature == #"["int","javascript","string","double"]"#)
    }

    @Test("Above the last level each child pairs its own name with its children's signature")
    func nestedSignature() throws {
        let signature = try expectedSignature(
            #"{"_id":{"$numberInt":"1"},"o":{"x":{"$numberLong":"2"}},"a":[{"$numberInt":"3"},"s"]}"#
        )
        #expect(signature == #"[["int",[]],["object",["long"]],["array",["int","string"]]]"#)
    }

    @Test("A container is read by position and never through a field path, whatever its field names")
    func namesStayInsideTheLiteral() throws {
        let document = #"{"_id":{"$numberInt":"1"},"a.b":{"$numberInt":"1"},"":"e","x":{"$w":{"$numberInt":"1"}}}"#
        let text = try filter(document)
        let outsideLiteral = text.replacingOccurrences(of: document, with: "")
        #expect(!outsideLiteral.contains(#""a.b""#))
        #expect(!outsideLiteral.contains(#""$w""#))
        #expect(!outsideLiteral.contains(#""$a.b""#))
    }

    @Test("Every operator that could raise on what the field holds now is guarded")
    func totality() throws {
        let text = try filter(#"{"_id":{"$numberInt":"1"},"o":{"a":[{"b":{"$numberDecimal":"1"}}]}}"#)
        #expect(!text.contains("$toString"))
        #expect(!text.contains("$arrayElemAt"))
        let objectToArray = text.components(separatedBy: #"{"$objectToArray":"#).dropFirst()
        #expect(!objectToArray.isEmpty)
        #expect(objectToArray.allSatisfy { $0.hasPrefix(#"{"$cond":[{"$eq":[{"$type":"#) })
        let conversions = text.components(separatedBy: #"{"$convert":"#).dropFirst()
        #expect(conversions.allSatisfy { $0.hasPrefix(#"{"input":"$$this","to":"string","onError":"","onNull":""}"#) })
    }

    @Test("A document as deep as libbson can read the filter of builds, and one level more is refused")
    func depthLimit() throws {
        func nested(_ depth: Int) -> String {
            var value = #"{"$numberInt":"1"}"#
            for _ in 0 ..< depth - 1 {
                value = #"{"k":\#(value)}"#
            }
            return #"{"_id":{"$numberInt":"1"},"v":\#(value)}"#
        }
        let deepest = try MongoDocumentText(parsing: nested(MongoDocumentGuard.maximumDepth))
        #expect(try MongoDocumentGuard.depth(of: .object(deepest.members)) == MongoDocumentGuard.maximumDepth)
        _ = try MongoDocumentGuard.filter(for: deepest)
        #expect(throws: MongoDocumentGuard.Refusal.tooDeep) {
            try filter(nested(MongoDocumentGuard.maximumDepth + 1))
        }
    }

    @Test("A type marker is one value, not a level of nesting")
    func markersAreScalars() throws {
        let document = try MongoDocumentText(
            parsing: #"{"_id":{"$oid":"65f0a1b2c3d4e5f607182930"},"d":{"$date":{"$numberLong":"0"}}}"#
        )
        #expect(try MongoDocumentGuard.depth(of: .object(document.members)) == 1)
    }

    @Test("A document with no _id has nothing to guard")
    func missingIdentity() {
        #expect(throws: MongoDBDocumentEditingError.missingIdentity) {
            try filter(#"{"a":{"$numberInt":"1"}}"#)
        }
    }
}
