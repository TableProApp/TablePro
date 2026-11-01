//
//  ProtobufSchemaDecoderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// Fixtures written by `protoc --encode` (libprotoc 36.2); every expected text is `protoc --decode` output for them.
struct ProtobufSchemaDecoderTests {
    private static let shopProto = """
        syntax = "proto3";
        package shop;

        // Every scalar type, an enum, packed and unpacked repeats, a map, a oneof and nesting.
        message Item {
          int32 i32 = 1;
          int64 i64 = 2;
          uint32 u32 = 3;
          uint64 u64 = 4;
          sint32 s32 = 5;
          sint64 s64 = 6;
          fixed32 f32 = 7;
          fixed64 f64 = 8;
          sfixed32 sf32 = 9;
          sfixed64 sf64 = 10;
          float fl = 11;
          double db = 12;
          bool flag = 13;
          string name = 14;
          bytes raw = 15;
          Color color = 16;
          repeated int32 packed = 17;
          repeated string labels = 18;
          map<string, Inner> inners = 19;
          Inner inner = 20;
          oneof choice {
            string text = 21;
            int32 number = 22;
          }
          message Inner {
            string note = 1;
            repeated Color colors = 2;
          }
        }

        enum Color {
          RED = 0;
          GREEN = 1;
          BLUE = 2;
        }

        message Other {
          string x = 1;
        }
        """

    // protoc --descriptor_set_out=shop.desc shop.proto
    private static let shopDescriptorSet = "0ae7050a0a73686f702e70726f746f120473686f70228c050a044974656d12100a03693332180120012805520369333212100a036936341802200128"
        + "03520369363412100a0375333218032001280d520375333212100a03753634180420012804520375363412100a037333321805200128115203733332"
        + "12100a03733634180620012812520373363412100a03663332180720012807520366333212100a03663634180820012806520366363412120a047366"
        + "333218092001280f52047366333212120a0473663634180a20012810520473663634120e0a02666c180b200128025202666c120e0a026462180c2001"
        + "28015202646212120a04666c6167180d200128085204666c616712120a046e616d65180e2001280952046e616d6512100a03726177180f2001280c52"
        + "0372617712210a05636f6c6f7218102001280e320b2e73686f702e436f6c6f725205636f6c6f7212160a067061636b65641811200328055206706163"
        + "6b656412160a066c6162656c7318122003280952066c6162656c73122e0a06696e6e65727318132003280b32162e73686f702e4974656d2e496e6e65"
        + "7273456e7472795206696e6e65727312260a05696e6e657218142001280b32102e73686f702e4974656d2e496e6e65725205696e6e657212140a0474"
        + "657874181520012809480052047465787412180a066e756d626572181620012805480052066e756d6265721a4b0a0b496e6e657273456e7472791210"
        + "0a036b657918012001280952036b657912260a0576616c756518022001280b32102e73686f702e4974656d2e496e6e6572520576616c75653a023801"
        + "1a400a05496e6e657212120a046e6f746518012001280952046e6f746512230a06636f6c6f727318022003280e320b2e73686f702e436f6c6f725206"
        + "636f6c6f727342080a0663686f69636522150a054f74686572120c0a01781801200128095201782a250a05436f6c6f7212070a03524544100012090a"
        + "05475245454e100112080a04424c55451002620670726f746f33"

    private static let item = "08fbffffffffffffffff011080ccbbbcdeffffffff011880d0acf30e208080a0a89c94b6e6f901280d30ffef99c589043d7b00000041c801000000"
        + "0000004df8ffffff51f7ffffffffffffff5d0000c03f619a9999999999b93f680172075461622250726f7a030102ff8001028a01040102ac0292010161"
        + "920101629a010d0a026b3112070a016e12020102a201060a0464656570b0012a"

    private static let itemText = """
        i32: -5
        i64: -9000000000
        u32: 4000000000
        u64: 18000000000000000000
        s32: -7
        s64: -70000000000
        f32: 123
        f64: 456
        sf32: -8
        sf64: -9
        fl: 1.5
        db: 0.1
        flag: true
        name: "Tab\\"Pro"
        raw: "\\001\\002\\377"
        color: BLUE
        packed: 1
        packed: 2
        packed: 300
        labels: "a"
        labels: "b"
        inners {
          key: "k1"
          value {
            note: "n"
            colors: GREEN
            colors: BLUE
          }
        }
        inner {
          note: "deep"
        }
        number: 42

        """

    private static func text(_ hex: String, schema: ProtobufSchema, message: String?, multiLine: Bool = true) throws -> String {
        let decoded = try ProtobufSchemaDecoder.decode(BinaryFixture.data(hex), schema: schema, message: message)
        return ProtobufSchemaTextWriter.text(decoded.fields, multiLine: multiLine)
    }

    @Test("A .proto file reads every type the way protoc --decode prints it")
    func protoFile() throws {
        let schema = try ProtobufSchema.parse(Data(Self.shopProto.utf8))
        #expect(schema.messageNames == ["shop.Item", "shop.Item.Inner", "shop.Other"])
        #expect(try Self.text(Self.item, schema: schema, message: "shop.Item") == Self.itemText)
    }

    @Test("A descriptor set from protoc reads the same as the .proto it was built from")
    func descriptorSet() throws {
        let schema = try ProtobufSchema.parse(BinaryFixture.data(Self.shopDescriptorSet))
        #expect(schema == (try ProtobufSchema.parse(Data(Self.shopProto.utf8))))
        #expect(try Self.text(Self.item, schema: schema, message: "shop.Item") == Self.itemText)
    }

    @Test("Fields the message does not declare, or declares with another wire type, show by number")
    func unknownFields() throws {
        let schema = try ProtobufSchema.parse(Data(Self.shopProto.utf8))
        let text = try Self.text(Self.item, schema: schema, message: "shop.Other")
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.prefix(3) == ["1: 18446744073709551611", "2: 18446744064709551616", "3: 4000000000"])
        #expect(lines.contains("7: 0x0000007b"))
        #expect(lines.contains(#"17: "\001\002\254\002""#))
        #expect(lines.last == "22: 42")
    }

    @Test("A proto2 group and packed and unpacked repeats")
    func proto2() throws {
        let proto = """
            syntax = "proto2";
            package legacy;

            message Msg {
              optional int32 id = 1;
              repeated group Entry = 2 {
                optional string k = 3;
              }
              repeated int32 nums = 4 [packed = true];
              repeated int32 loose = 5;
              optional float ratio = 6;
            }
            """
        let schema = try ProtobufSchema.parse(Data(proto.utf8))
        let expected = "id: 1\nEntry {\n  k: \"a\"\n}\nEntry {\n  k: \"b\"\n}\nnums: 5\nnums: 6\nloose: 7\nloose: 8\nratio: 0.1\n"
        #expect(try Self.text("0801131a016114131a016214220205062807280835cdcccc3d", schema: schema, message: "legacy.Msg") == expected)
    }

    @Test("The tree names each field and badges it with its declared type")
    func tree() throws {
        let schema = try ProtobufSchema.parse(Data(Self.shopProto.utf8))
        let message = try ProtobufSchemaDecoder.decode(BinaryFixture.data(Self.item), schema: schema, message: "shop.Item")
        let root = ProtobufSchemaTreeBuilder.build(from: message, formats: BinaryFixture.english)
        #expect(root.badgeLabel == "Item")
        let color = try #require(root.children.first { $0.key == "color" })
        #expect(color.badgeLabel == "Color")
        #expect(color.displayValue == "BLUE")
        let inner = try #require(root.children.first { $0.key == "inner" })
        #expect(inner.badgeLabel == "Inner")
        #expect(inner.copyableValue == #"note: "deep""#)
        #expect(root.children.first { $0.key == "s64" }?.badgeLabel == "sint64")
    }

    @Test("The one-line text a cell shows")
    func singleLine() throws {
        let schema = try ProtobufSchema.parse(Data(Self.shopProto.utf8))
        #expect(try Self.text("a201060a0464656570", schema: schema, message: "shop.Item", multiLine: false) == #"inner { note: "deep" }"#)
    }

    @Test("A singular message sent twice is merged, as a parser does")
    func mergesSingularMessages() throws {
        let schema = try ProtobufSchema.parse(Data(Self.shopProto.utf8))
        #expect(try Self.text("a201030a0161a20103120101", schema: schema, message: "shop.Item")
            == "inner {\n  note: \"a\"\n  colors: GREEN\n}\n")
    }

    @Test("A cell stops reading a packed field at its budget")
    func packedFieldBudget() throws {
        let schema = try ProtobufSchema.parse(Data(Self.shopProto.utf8))
        let packed = "8a01" + "c801" + String(repeating: "01", count: 200)
        let message = try ProtobufSchemaDecoder.decode(BinaryFixture.data(packed), schema: schema, message: "shop.Item", maxValues: 10)
        #expect(message.fields.count < 20)
        #expect(message.fields.last?.value == .truncated)
    }

    @Test("A broken value is refused, so the cell falls back to hex")
    func brokenValue() throws {
        let schema = try ProtobufSchema.parse(Data(Self.shopProto.utf8))
        #expect(throws: BinaryValueDecodeError.self) {
            try ProtobufSchemaDecoder.decode(BinaryFixture.data("0a05ab"), schema: schema, message: "shop.Item")
        }
        #expect(throws: BinaryValueDecodeError.self) {
            try ProtobufSchemaDecoder.decode(BinaryFixture.data("0f"), schema: schema, message: "shop.Item")
        }
    }

    @Test("A file that is not a schema says why")
    func invalidSchema() {
        #expect(throws: ProtobufSchemaError.self) { try ProtobufSchema.parse(Data("message Item { int32 id = ; }".utf8)) }
        #expect(throws: ProtobufSchemaError.self) { try ProtobufSchema.parse(Data("enum Only { A = 0; }".utf8)) }
        #expect(throws: ProtobufSchemaError.self) { try ProtobufSchema.parse(Data([0xFF, 0x00, 0x13])) }
    }
}
