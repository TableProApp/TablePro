//
//  MongoDBUuidCodecTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

enum BsonUuidFixture {
    static let uuidString = "8cd003eb-4a25-4324-9332-88fce2da0d1a"
    static let standardBytes = bytes("8cd003eb4a254324933288fce2da0d1a")
    static let javaBytes = bytes("2443254aeb03d08c1a0ddae2fc883293")
    static let csharpBytes = bytes("eb03d08c254a2443933288fce2da0d1a")

    static func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
            index = next
        }
        return result
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

@Suite("MongoDB UUID Codec")
struct MongoDBUuidCodecTests {
    /// Vectors from the MongoDB BSON Binary UUID specification test plan.
    @Suite("Specification vectors")
    struct SpecificationVectorTests {
        static let specUuid = "00112233-4455-6677-8899-aabbccddeeff"
        static let mongoshUuid = "01234567-89ab-cdef-0123-456789abcdef"

        @Test("Standard subtype 4 uses RFC 4122 byte order")
        func standardOrder() {
            let binary = MongoDBBinaryValue(
                data: Data(BsonUuidFixture.bytes("00112233445566778899aabbccddeeff")), subtype: 0x04
            )
            let text = MongoDBUuidCodec.decodedText(for: binary, representation: .unspecified)
            #expect(text == "UUID(\"\(Self.specUuid)\")")
        }

        @Test("Java legacy reverses each 8-byte half")
        func javaOrder() {
            let binary = MongoDBBinaryValue(
                data: Data(BsonUuidFixture.bytes("7766554433221100ffeeddccbbaa9988")), subtype: 0x03
            )
            let text = MongoDBUuidCodec.decodedText(for: binary, representation: .javaLegacy)
            #expect(text == "LegacyJavaUUID(\"\(Self.specUuid)\")")
        }

        @Test("C# legacy reverses the first three GUID groups")
        func csharpOrder() {
            let binary = MongoDBBinaryValue(
                data: Data(BsonUuidFixture.bytes("33221100554477668899aabbccddeeff")), subtype: 0x03
            )
            let text = MongoDBUuidCodec.decodedText(for: binary, representation: .csharpLegacy)
            #expect(text == "LegacyCSharpUUID(\"\(Self.specUuid)\")")
        }

        @Test("Python legacy keeps RFC 4122 byte order")
        func pythonOrder() {
            let binary = MongoDBBinaryValue(
                data: Data(BsonUuidFixture.bytes("00112233445566778899aabbccddeeff")), subtype: 0x03
            )
            let text = MongoDBUuidCodec.decodedText(for: binary, representation: .pythonLegacy)
            #expect(text == "LegacyPythonUUID(\"\(Self.specUuid)\")")
        }

        @Test("Java legacy matches the mongosh end-to-end vector")
        func mongoshJavaVector() {
            let binary = MongoDBBinaryValue(
                data: Data(BsonUuidFixture.bytes("efcdab8967452301efcdab8967452301")), subtype: 0x03
            )
            let text = MongoDBUuidCodec.decodedText(for: binary, representation: .javaLegacy)
            #expect(text == "LegacyJavaUUID(\"\(Self.mongoshUuid)\")")
        }

        @Test("C# legacy matches the mongosh end-to-end vector")
        func mongoshCsharpVector() {
            let binary = MongoDBBinaryValue(
                data: Data(BsonUuidFixture.bytes("67452301ab89efcd0123456789abcdef")), subtype: 0x03
            )
            let text = MongoDBUuidCodec.decodedText(for: binary, representation: .csharpLegacy)
            #expect(text == "LegacyCSharpUUID(\"\(Self.mongoshUuid)\")")
        }

        @Test("Java legacy decodes the UUID reported in the issue")
        func reportedIssueVector() {
            let binary = MongoDBBinaryValue(data: Data(BsonUuidFixture.javaBytes), subtype: 0x03)
            let text = MongoDBUuidCodec.decodedText(for: binary, representation: .javaLegacy)
            #expect(text == "LegacyJavaUUID(\"\(BsonUuidFixture.uuidString)\")")
        }

        @Test("C# legacy decodes the UUID reported in the issue")
        func reportedIssueCsharpVector() {
            let binary = MongoDBBinaryValue(data: Data(BsonUuidFixture.csharpBytes), subtype: 0x03)
            let text = MongoDBUuidCodec.decodedText(for: binary, representation: .csharpLegacy)
            #expect(text == "LegacyCSharpUUID(\"\(BsonUuidFixture.uuidString)\")")
        }
    }

    @Suite("Decode guards")
    struct DecodeGuardTests {
        @Test("Legacy subtype stays undecoded when no representation is configured")
        func unspecifiedRefusesLegacy() {
            let binary = MongoDBBinaryValue(data: Data(BsonUuidFixture.javaBytes), subtype: 0x03)
            #expect(MongoDBUuidCodec.decodedText(for: binary, representation: .unspecified) == nil)
            #expect(!MongoDBUuidCodec.isDecodableUuid(binary, representation: .unspecified))
        }

        @Test("Standard subtype decodes regardless of representation")
        func standardIgnoresRepresentation() {
            let binary = MongoDBBinaryValue(data: Data(BsonUuidFixture.standardBytes), subtype: 0x04)
            for representation in MongoDBUuidRepresentation.allCases {
                #expect(
                    MongoDBUuidCodec.decodedText(for: binary, representation: representation)
                        == "UUID(\"\(BsonUuidFixture.uuidString)\")"
                )
            }
        }

        @Test("Binary that is not exactly 16 bytes never decodes", arguments: [0, 1, 15, 17, 32])
        func rejectsWrongLength(count: Int) {
            let binary = MongoDBBinaryValue(data: Data(repeating: 0x01, count: count), subtype: 0x03)
            #expect(MongoDBUuidCodec.decodedText(for: binary, representation: .javaLegacy) == nil)
        }

        @Test("Subtypes other than 3 and 4 never decode", arguments: [0x00, 0x01, 0x02, 0x05, 0x07, 0x80])
        func rejectsOtherSubtypes(subtype: Int) {
            let binary = MongoDBBinaryValue(
                data: Data(BsonUuidFixture.standardBytes), subtype: UInt8(subtype)
            )
            #expect(MongoDBUuidCodec.decodedText(for: binary, representation: .javaLegacy) == nil)
        }

        @Test("Undecoded binary reports its real subtype, not its length")
        func binaryTextCarriesSubtype() {
            let binary = MongoDBBinaryValue(data: Data([0xDE, 0xAD, 0xBE, 0xEF]), subtype: 0x05)
            #expect(MongoDBUuidCodec.binaryText(for: binary) == "BinData(5, \"3q2+7w==\")")
        }
    }

    @Suite("Round trip")
    struct RoundTripTests {
        @Test("Every representation round-trips through its own wrapper")
        func wrapperRoundTrip() throws {
            let cases: [(MongoDBUuidRepresentation, UInt8, [UInt8])] = [
                (.unspecified, 0x04, BsonUuidFixture.standardBytes),
                (.javaLegacy, 0x03, BsonUuidFixture.javaBytes),
                (.csharpLegacy, 0x03, BsonUuidFixture.csharpBytes),
                (.pythonLegacy, 0x03, BsonUuidFixture.standardBytes),
            ]
            for (representation, subtype, storedBytes) in cases {
                let original = MongoDBBinaryValue(data: Data(storedBytes), subtype: subtype)
                let text = try #require(
                    MongoDBUuidCodec.decodedText(for: original, representation: representation)
                )
                #expect(MongoDBUuidCodec.parseWrapper(text) == original)
            }
        }

        @Test("The wrapper tag decides the byte order, not the configured representation")
        func tagWinsOverConfiguration() throws {
            let parsed = try #require(
                MongoDBUuidCodec.parseWrapper("LegacyJavaUUID(\"\(BsonUuidFixture.uuidString)\")")
            )
            #expect(BsonUuidFixture.hex(parsed.data) == "2443254aeb03d08c1a0ddae2fc883293")
            #expect(parsed.subtype == 0x03)
        }

        @Test("Studio 3T spellings are accepted as input aliases")
        func acceptsLegacyToolAliases() throws {
            let java = try #require(MongoDBUuidCodec.parseWrapper("JUUID(\"\(BsonUuidFixture.uuidString)\")"))
            #expect(java.data == Data(BsonUuidFixture.javaBytes))

            let csharp = try #require(MongoDBUuidCodec.parseWrapper("CSUUID(\"\(BsonUuidFixture.uuidString)\")"))
            #expect(csharp.data == Data(BsonUuidFixture.csharpBytes))

            let nuuid = try #require(MongoDBUuidCodec.parseWrapper("NUUID(\"\(BsonUuidFixture.uuidString)\")"))
            #expect(nuuid.data == Data(BsonUuidFixture.csharpBytes))

            let python = try #require(MongoDBUuidCodec.parseWrapper("PYUUID(\"\(BsonUuidFixture.uuidString)\")"))
            #expect(python.data == Data(BsonUuidFixture.standardBytes))

            let raw = try #require(MongoDBUuidCodec.parseWrapper("LUUID(\"\(BsonUuidFixture.uuidString)\")"))
            #expect(raw.data == Data(BsonUuidFixture.standardBytes))
            #expect(raw.subtype == 0x03)
        }

        @Test("Single quotes and braces are accepted")
        func acceptsQuoteAndBraceVariants() throws {
            let single = try #require(MongoDBUuidCodec.parseWrapper("UUID('\(BsonUuidFixture.uuidString)')"))
            #expect(single.data == Data(BsonUuidFixture.standardBytes))

            let braced = try #require(MongoDBUuidCodec.parseWrapper("UUID(\"{\(BsonUuidFixture.uuidString)}\")"))
            #expect(braced.data == Data(BsonUuidFixture.standardBytes))

            let unhyphenated = try #require(
                MongoDBUuidCodec.parseWrapper("UUID(\"8cd003eb4a254324933288fce2da0d1a\")")
            )
            #expect(unhyphenated.data == Data(BsonUuidFixture.standardBytes))
        }

        @Test(
            "Text that is not a UUID wrapper is rejected",
            arguments: [
                "",
                "hello",
                "UUID()",
                "UUID(\"not-a-uuid\")",
                "UUID(\"8cd003eb-4a25-4324-9332-88fce2da0d1\")",
                "NotAUUID(\"8cd003eb-4a25-4324-9332-88fce2da0d1a\")",
                "UUID(8cd003eb-4a25-4324-9332-88fce2da0d1a)",
                "UUID(\"8cd003eb-4a25-4324-9332-88fce2da0d1a\"",
                "{\"$binary\": {\"base64\": \"jNAD60olQySTMoj84toNGg==\", \"subType\": \"04\"}}",
            ]
        )
        func rejectsNonWrappers(text: String) {
            #expect(MongoDBUuidCodec.parseWrapper(text) == nil)
        }
    }

    @Suite("Extended JSON")
    struct ExtendedJsonTests {
        @Test("Legacy subtype serializes as two-digit hex")
        func legacySubtypeHex() {
            let binary = MongoDBBinaryValue(data: Data(BsonUuidFixture.javaBytes), subtype: 0x03)
            #expect(
                MongoDBUuidCodec.extendedJson(for: binary)
                    == "{\"$binary\": {\"base64\": \"JEMlSusD0IwaDdri/Igykw==\", \"subType\": \"03\"}}"
            )
        }

        @Test("Standard subtype serializes as two-digit hex")
        func standardSubtypeHex() {
            let binary = MongoDBBinaryValue(data: Data(BsonUuidFixture.standardBytes), subtype: 0x04)
            #expect(
                MongoDBUuidCodec.extendedJson(for: binary)
                    == "{\"$binary\": {\"base64\": \"jNAD60olQySTMoj84toNGg==\", \"subType\": \"04\"}}"
            )
        }

        @Test("A wrapper converts straight to Extended JSON for the write path")
        func wrapperToExtendedJson() {
            let json = MongoDBUuidCodec.extendedJsonFromWrapper(
                "LegacyJavaUUID(\"\(BsonUuidFixture.uuidString)\")"
            )
            #expect(json == "{\"$binary\": {\"base64\": \"JEMlSusD0IwaDdri/Igykw==\", \"subType\": \"03\"}}")
        }

        @Test("Serialized Extended JSON parses back as valid JSON")
        func extendedJsonIsValid() throws {
            let binary = MongoDBBinaryValue(data: Data(BsonUuidFixture.javaBytes), subtype: 0x03)
            let data = try #require(MongoDBUuidCodec.extendedJson(for: binary).data(using: .utf8))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let payload = try #require(object?["$binary"] as? [String: Any])
            #expect(payload["subType"] as? String == "03")
            #expect(payload["base64"] as? String == Data(BsonUuidFixture.javaBytes).base64EncodedString())
        }
    }

    @Suite("Representation resolution")
    struct RepresentationTests {
        @Test(
            "An unset, empty or unknown value resolves to unspecified",
            arguments: [nil, "", "   ", "javalegacy", "standard", "nonsense"] as [String?]
        )
        func resolvesToUnspecified(rawValue: String?) {
            #expect(MongoDBUuidRepresentation.resolve(rawValue) == .unspecified)
        }

        @Test("Specification spellings resolve to their representation")
        func resolvesSpecSpellings() {
            #expect(MongoDBUuidRepresentation.resolve("javaLegacy") == .javaLegacy)
            #expect(MongoDBUuidRepresentation.resolve("csharpLegacy") == .csharpLegacy)
            #expect(MongoDBUuidRepresentation.resolve("pythonLegacy") == .pythonLegacy)
        }
    }
}
