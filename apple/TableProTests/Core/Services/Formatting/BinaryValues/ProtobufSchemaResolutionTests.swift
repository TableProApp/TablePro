import Foundation
@testable import TablePro
import Testing

private func fieldTypes(_ schema: ProtobufSchema, _ message: String) -> [String: ProtobufFieldType] {
    Dictionary(uniqueKeysWithValues: (schema.messages[message]?.fields ?? []).map { ($0.name, $0.type) })
}

private func lengthDelimited(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
    var bytes = [UInt8(number << 3 | 2)]
    var length = payload.count
    while length >= 0x80 {
        bytes.append(UInt8(length & 0x7F | 0x80))
        length >>= 7
    }
    bytes.append(UInt8(length))
    return bytes + payload
}

struct ProtobufSchemaResolutionTests {
    @Test func referencesResolveFromTheInnermostScopeOutward() throws {
        let proto = """
            syntax = "proto3";
            package a.b;
            enum Color { RED = 0; }
            message Outer {
              message Inner { int32 v = 1; }
              Inner inner = 1;
              b.Outer qualified = 2;
              Outer.Inner nested = 3;
              Missing missing = 4;
              .a.b.Color absolute = 5;
              Color color = 6;
            }
            """
        let types = fieldTypes(try ProtobufSchema.parse(Data(proto.utf8)), "a.b.Outer")
        #expect(types["inner"] == .message("a.b.Outer.Inner"))
        #expect(types["qualified"] == .message("a.b.Outer"))
        #expect(types["nested"] == .message("a.b.Outer.Inner"))
        #expect(types["missing"] == .unresolved("Missing"))
        #expect(types["absolute"] == .enumeration("a.b.Color"))
        #expect(types["color"] == .enumeration("a.b.Color"))
    }

    @Test func oneofsAreNumberedInDeclarationOrder() throws {
        let proto = """
            syntax = "proto3";
            message M {
              oneof first { int32 a = 1; string b = 2; }
              int32 plain = 3;
              oneof second { int32 c = 4; }
            }
            """
        let fields = try #require(try ProtobufSchema.parse(Data(proto.utf8)).messages["M"]?.fields)
        let indexes = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.oneofIndex) })
        #expect(indexes == ["a": 0, "b": 0, "plain": nil, "c": 1])
    }

    @Test func aCompoundNameWhoseFirstPartIsAnEnumIsNotLookedUpFurtherOut() throws {
        let inner = """
            syntax = "proto3";
            package a.b;
            message M {
              enum E { X = 0; }
              E.Inner f = 1;
            }
            """
        let outer = """
            syntax = "proto3";
            package a;
            message E { message Inner { int32 v = 1; } }
            """
        let types = fieldTypes(try ProtobufSchema.parse(protoFiles: [inner, outer]), "a.b.M")
        #expect(types["f"] == .unresolved("E.Inner"))
    }

    // Each field looked its type up through every part of the package: 10,000 parts and 2,000 fields took 15 s.
    @Test(.timeLimit(.minutes(1)))
    func aPackageOfTooManyPartsIsRefused() throws {
        let fields = (1...2_000).map { "  Missing\($0) f\($0) = \($0);" }.joined(separator: "\n")
        func proto(parts: Int) -> String {
            let package = Array(repeating: "p", count: parts).joined(separator: ".")
            return "syntax = \"proto3\";\npackage \(package);\nmessage M {\n\(fields)\n}\n"
        }
        #expect(throws: ProtobufSchemaError(reason: String(localized: "The package name has too many parts."))) {
            try ProtobufSchema.parse(Data(proto(parts: 10_000).utf8))
        }
        let package = Array(repeating: "p", count: ProtoFileParser.maxPackageComponents).joined(separator: ".")
        let types = fieldTypes(try ProtobufSchema.parse(Data(proto(parts: ProtoFileParser.maxPackageComponents).utf8)), "\(package).M")
        #expect(types["f2000"] == .unresolved("Missing2000"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aDottedMessageNameIsRefused() {
        let name = Array(repeating: "p", count: 10_000).joined(separator: ".")
        let fields = (1...2_000).map { "  Missing\($0) f\($0) = \($0);" }.joined(separator: "\n")
        let proto = "syntax = \"proto3\";\nmessage \(name) {\n\(fields)\n}\n"
        #expect(throws: ProtobufSchemaError.self) {
            try ProtobufSchema.parse(Data(proto.utf8))
        }
    }

    // Splitting the package again for each field cost fields times its length in characters.
    @Test(.timeLimit(.minutes(1)))
    func aLongPackageNameResolvesInLinearTime() throws {
        let package = String(repeating: "p", count: ProtoFileParser.maxNameLength - 10)
        let fields = (1...30_000).map { "  Missing\($0) f\($0) = \($0);" }.joined(separator: "\n")
        let proto = "syntax = \"proto3\";\npackage \(package);\nmessage M {\n\(fields)\n}\n"
        let types = fieldTypes(try ProtobufSchema.parse(Data(proto.utf8)), "\(package).M")
        #expect(types.count == 30_000)
        #expect(types["f30000"] == .unresolved("Missing30000"))
    }

    // Each message keeps its full name, so a 2 MB package over 180,000 empty messages asked for 360 GB.
    @Test(.timeLimit(.minutes(1)))
    func aTypeNamePastTheLimitIsRefused() {
        let package = String(repeating: "p", count: 2_000_000)
        let messages = (1...180_000).map { "message A\($0) {}" }.joined(separator: "\n")
        let proto = "syntax = \"proto3\";\npackage \(package);\n\(messages)\n"
        #expect(throws: ProtobufSchemaError(reason: String(localized: "A type name is too long."))) {
            try ProtobufSchema.parse(Data(proto.utf8))
        }
    }

    @Test func moreEnumsThanTheLimitAreRefused() {
        let enums = (0...ProtobufSchema.maxMessages).map { "enum E\($0) { V\($0) = 0; }" }.joined(separator: "\n")
        let proto = "syntax = \"proto3\";\nmessage M {}\n\(enums)\n"
        #expect(throws: ProtobufSchemaError(reason: String(localized: "The schema defines more messages than TablePro reads."))) {
            try ProtobufSchema.parse(Data(proto.utf8))
        }
    }

    @Test func definitionsAcrossFilesAreCountedTogether() {
        let files = (0..<3).map { file in
            let enums = (0..<15_000).map { "enum E\(file)x\($0) { V\(file)x\($0) = 0; }" }.joined(separator: "\n")
            return "syntax = \"proto3\";\npackage f\(file);\nmessage M {}\n\(enums)\n"
        }
        #expect(throws: ProtobufSchemaError(reason: String(localized: "The schema defines more messages than TablePro reads."))) {
            try ProtobufSchema.parse(protoFiles: files)
        }
    }

    @Test func moreMessagesThanTheLimitAreRefused() {
        let messages = (0...ProtobufSchema.maxMessages).map { "message A\($0) {}" }.joined(separator: "\n")
        let proto = "syntax = \"proto3\";\n\(messages)\n"
        #expect(throws: ProtobufSchemaError(reason: String(localized: "The schema defines more messages than TablePro reads."))) {
            try ProtobufSchema.parse(Data(proto.utf8))
        }
    }

    @Test func aDescriptorSetPackageOfTooManyPartsIsRefused() throws {
        func descriptorSet(packageParts: Int) -> Data {
            let package = Array(repeating: "p", count: packageParts).joined(separator: ".")
            let message = lengthDelimited(1, Array("M".utf8))
            let file = lengthDelimited(1, Array("m.proto".utf8)) + lengthDelimited(2, Array(package.utf8))
                + lengthDelimited(4, message)
            return Data(lengthDelimited(1, file))
        }
        #expect(throws: ProtobufSchemaError(reason: String(localized: "The package name has too many parts."))) {
            try ProtobufSchema.parse(descriptorSet(packageParts: ProtoFileParser.maxPackageComponents + 1))
        }
        let schema = try ProtobufSchema.parse(descriptorSet(packageParts: ProtoFileParser.maxPackageComponents))
        #expect(schema.messageNames.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func manyOneofsAreNumberedInLinearTime() throws {
        let count = 40_000
        let oneofs = (1...count).map { "  oneof o\($0) { int32 f\($0) = \($0); }" }.joined(separator: "\n")
        let proto = "syntax = \"proto3\";\nmessage M {\n\(oneofs)\n}\n"
        let fields = try #require(try ProtobufSchema.parse(Data(proto.utf8)).messages["M"]?.fields)
        #expect(fields.count == count)
        #expect(fields.last?.oneofIndex == count - 1)
    }
}
