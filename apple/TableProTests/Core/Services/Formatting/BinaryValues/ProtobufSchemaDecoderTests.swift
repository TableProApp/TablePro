//
//  ProtobufSchemaDecoderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// libprotoc 36.2. Each fixture says how it was written; every expected text is `protoc --decode` output for it.
struct ProtobufSchemaDecoderTests {
    private static let shopProto = """
        syntax = "proto3";
        package shop;

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

    // protoc --encode=shop.Item shop.proto
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

    private static let demoProto = """
        syntax = "proto3";
        package demo;

        message M {
          map<string, int32> m = 1;
          map<int32, string> im = 2;
          oneof choice {
            string text = 3;
            int32 number = 4;
            Inner pick = 5;
          }
          int32 count = 6;
          optional int32 opt = 7;
          string name = 8;
          bytes data = 9;
          E e = 10;
          double ratio = 11;
          Inner inner = 12;
        }

        enum E {
          E0 = 0;
          E1 = 1;
        }

        message Inner {
          int32 x = 1;
          int32 y = 2;
        }
        """

    // protoc --descriptor_set_out=demo.desc demo.proto
    private static let demoDescriptorSet = "0a90040a0a64656d6f2e70726f746f120464656d6f22b9030a014d121c0a016d18012003280b320e2e64656d6f2e4d2e4d456e74727952016d121f0a"
        + "02696d18022003280b320f2e64656d6f2e4d2e496d456e7472795202696d12140a0474657874180320012809480052047465787412180a066e756d62"
        + "6572180420012805480052066e756d62657212210a047069636b18052001280b320b2e64656d6f2e496e6e6572480052047069636b12140a05636f75"
        + "6e741806200128055205636f756e7412150a036f7074180720012805480152036f707488010112120a046e616d6518082001280952046e616d651212"
        + "0a046461746118092001280c52046461746112150a0165180a2001280e32072e64656d6f2e4552016512140a05726174696f180b2001280152057261"
        + "74696f12210a05696e6e6572180c2001280b320b2e64656d6f2e496e6e65725205696e6e65721a340a064d456e74727912100a036b65791801200128"
        + "0952036b657912140a0576616c7565180220012805520576616c75653a0238011a350a07496d456e74727912100a036b657918012001280552036b65"
        + "7912140a0576616c7565180220012809520576616c75653a02380142080a0663686f69636542060a045f6f707422230a05496e6e6572120c0a017818"
        + "0120012805520178120c0a01791802200128055201792a130a014512060a024530100012060a0245311001620670726f746f33"

    // protoc --encode=demo.M: m { key: "b" value: 1 } m { key: "a" value: 2 } m { key: "a" value: 3 }
    // im { key: 5 value: "x" } im { key: -1 value: "y" } im { key: 2 value: "z" }
    private static let maps = "0a050a016210010a050a016110020a050a0161100312050805120178120e08ffffffffffffffffff011201791205080212017a"

    private static let mapsText = """
        m {
          key: "a"
          value: 2
        }
        m {
          key: "a"
          value: 3
        }
        m {
          key: "b"
          value: 1
        }
        im {
          key: -1
          value: "y"
        }
        im {
          key: 2
          value: "z"
        }
        im {
          key: 5
          value: "x"
        }

        """

    // Hand-written: count, name, data, e and ratio at their defaults, then protoc --encode=demo.M of `opt: 0 inner {}`.
    private static let defaults = "300042004a00500059000000000000000038006200"

    private static let editionsProto = """
        edition = "2023";
        package ed;
        option features.field_presence = IMPLICIT;

        enum Open {
          O0 = 0;
          O1 = 1;
        }

        enum Closed {
          option features.enum_type = CLOSED;
          C0 = 0;
          C1 = 1;
        }

        message M {
          int32 a = 1;
          int32 b = 2 [features.field_presence = EXPLICIT];
          int32 c = 3 [features.field_presence = LEGACY_REQUIRED];
          Sub sub = 4;
          Open open = 5;
          Closed closed = 6 [features.field_presence = EXPLICIT];
          string s = 7;

          message Sub {
            int32 x = 1;
            int32 y = 2 [features.field_presence = EXPLICIT];
          }
        }
        """

    // protoc --descriptor_set_out=ed.desc ed.proto
    private static let editionsDescriptorSet = "0ab6020a0865642e70726f746f1202656422d9010a014d120c0a016118012001280552016112130a01621802200128054205aa010208015201621213"
        + "0a01631803200128054205aa01020803520163121b0a0373756218042001280b32092e65642e4d2e5375625203737562121c0a046f70656e18052001"
        + "280e32082e65642e4f70656e52046f70656e12290a06636c6f73656418062001280e320a2e65642e436c6f7365644205aa010208015206636c6f7365"
        + "64120c0a01731807200128095201731a280a03537562120c0a017818012001280552017812130a01791802200128054205aa010208015201792a160a"
        + "044f70656e12060a024f30100012060a024f3110012a1e0a06436c6f73656412060a024330100012060a02433110011a043a02100242059203020802"
        + "620865646974696f6e7370e807"

    // protoc --include_imports --descriptor_set_out=order.desc order.proto, where order.proto imports money.proto.
    private static let orderDescriptorSet = "0a570a0b6d6f6e65792e70726f746f12056d6f6e657922390a054d6f6e657912140a05756e6974731801200128035205756e697473121a0a08637572"
        + "72656e6379180220012809520863757272656e6379620670726f746f330acb010a0b6f726465722e70726f746f12056f726465721a0b6d6f6e65792e"
        + "70726f746f2285010a054f72646572120e0a0269641801200128095202696412220a05746f74616c18022001280b320c2e6d6f6e65792e4d6f6e6579"
        + "5205746f74616c122b0a0673746174757318032001280e32132e6f726465722e4f726465722e5374617475735206737461747573221b0a0653746174"
        + "757312070a034e4557100012080a04444f4e45100122180a044c696e6512100a03736b751801200128095203736b75620670726f746f33"

    private static let budgetProto = """
        syntax = "proto2";
        package budget;

        message Box {
          optional Part a = 1;
          optional Part b = 2;
          optional Part c = 3;
        }

        message Part {
          repeated int32 v = 1;
        }
        """

    @Test("Map entries print sorted by key, and a repeated key keeps every entry in wire order")
    func mapsSortByKey() throws {
        let schema = try ProtobufSchema.parse(Data(Self.demoProto.utf8))
        #expect(try Self.text(Self.maps, schema: schema, message: "demo.M") == Self.mapsText)
        // Hand-written: an empty entry, then one with a field 3 the entry does not declare.
        #expect(try Self.text("0a000a050a017a1809", schema: schema, message: "demo.M")
            == "m {\n  key: \"\"\n  value: 0\n}\nm {\n  key: \"z\"\n  value: 0\n}\n")
    }

    @Test("The oneof member set last wins, and a message member keeps only what follows the last switch to it")
    func oneofLastMemberWins() throws {
        let schema = try ProtobufSchema.parse(Data(Self.demoProto.utf8))
        // protoc --encode=demo.M of `text: "hello"` and of `number: 7`, joined in both orders.
        #expect(try Self.text("1a0568656c6c6f2007", schema: schema, message: "demo.M") == "number: 7\n")
        #expect(try Self.text("20071a0568656c6c6f", schema: schema, message: "demo.M") == "text: \"hello\"\n")
        // protoc --encode=demo.M of `pick { x: 1 }`, `number: 7` and `pick { y: 3 }`, joined.
        #expect(try Self.text("2a02080120072a021003", schema: schema, message: "demo.M") == "pick {\n  y: 3\n}\n")
    }

    @Test("A proto3 field at its default is left out, after the last value wins; optional and message fields stay")
    func implicitPresence() throws {
        let schema = try ProtobufSchema.parse(Data(Self.demoProto.utf8))
        // protoc --encode=demo.M of `count: 5`, then a hand-written `count: 0`.
        #expect(try Self.text("30053000", schema: schema, message: "demo.M").isEmpty)
        #expect(try Self.text(Self.defaults, schema: schema, message: "demo.M") == "opt: 0\ninner {\n}\n")
        // protoc --encode=demo.M of `ratio: -0`
        #expect(try Self.text("590000000000000080", schema: schema, message: "demo.M") == "ratio: -0\n")
    }

    @Test("A proto2 field prints whatever value the bytes carry")
    func proto2KeepsDefaults() throws {
        let proto = """
            syntax = "proto2";
            package legacy;
            message Msg {
              optional int32 n = 1;
              optional string s = 2;
            }
            """
        let schema = try ProtobufSchema.parse(Data(proto.utf8))
        // protoc --encode=legacy.Msg of `n: 0 s: ""`
        #expect(try Self.text("08001200", schema: schema, message: "legacy.Msg") == "n: 0\ns: \"\"\n")
    }

    @Test("A number a closed enum does not declare goes to the unknown fields, a map entry with it whole")
    func closedEnumUnknownNumbers() throws {
        let proto = """
            syntax = "proto2";
            package legacy;

            enum Level {
              LOW = 0;
              HIGH = 1;
            }

            message Msg {
              optional int32 n = 1;
              optional string s = 2;
              optional Level level = 3;
              repeated Level levels = 4 [packed = true];
              map<int32, Level> named = 5;
            }
            """
        let schema = try ProtobufSchema.parse(Data(proto.utf8))
        // protoc --encode=legacy.Msg of `level: HIGH`, then hand-written: level 7, 99: 1, levels packed [1, 9, 0],
        // named { 4: 8 } and named { 2: HIGH }.
        let fixture = "1801180798060122030109002a04080410082a0408021001"
        let expected = "level: HIGH\nlevels: HIGH\nlevels: LOW\nnamed {\n  key: 2\n  value: HIGH\n}\n3: 7\n99: 1\n4: 9\n"
            + "5 {\n  1: 4\n  2: 8\n}\n"
        #expect(try Self.text(fixture, schema: schema, message: "legacy.Msg") == expected)
    }

    @Test("Editions presence follows features.field_presence on the file and the field")
    func editionsPresence() throws {
        let schema = try ProtobufSchema.parse(Data(Self.editionsProto.utf8))
        let descriptorSet = try ProtobufSchema.parse(BinaryFixture.data(Self.editionsDescriptorSet))
        #expect(descriptorSet == schema)
        // Hand-written: every field of ed.M at zero, sub with x and y at zero.
        let zeros = "080010001800220408001000280030003a00"
        let expected = "b: 0\nc: 0\nsub {\n  y: 0\n}\nclosed: C0\n"
        #expect(try Self.text(zeros, schema: schema, message: "ed.M") == expected)
        #expect(try Self.text(zeros, schema: descriptorSet, message: "ed.M") == expected)
        // Hand-written: a 1, closed 7, open 7.
        #expect(try Self.text("080130072807", schema: schema, message: "ed.M") == "a: 1\nopen: 7\n6: 7\n")
    }

    @Test("A descriptor set reads the same as the .proto protoc built it from")
    func descriptorSetMatchesProto() throws {
        let schema = try ProtobufSchema.parse(Data(Self.demoProto.utf8))
        let descriptorSet = try ProtobufSchema.parse(BinaryFixture.data(Self.demoDescriptorSet))
        #expect(descriptorSet == schema)
        #expect(try Self.text(Self.maps, schema: descriptorSet, message: "demo.M") == Self.mapsText)
        #expect(try Self.text(Self.defaults, schema: descriptorSet, message: "demo.M") == "opt: 0\ninner {\n}\n")
    }

    @Test("A descriptor set that does not read says it is not a schema")
    func brokenDescriptorSet() {
        // order.desc's money.proto with its last three bytes cut, framed as a set again.
        let truncated = "0a540a0b6d6f6e65792e70726f746f12056d6f6e657922390a054d6f6e657912140a05756e6974731801200128035205756e697473121a0a0863"
            + "757272656e6379180220012809520863757272656e6379620670726f"
        #expect(throws: ProtobufSchemaError.notASchema) { try ProtobufSchema.parse(BinaryFixture.data(truncated)) }
        // Hand-written: a file whose message names more bytes than it holds.
        #expect(throws: ProtobufSchemaError.notASchema) { try ProtobufSchema.parse(BinaryFixture.data("0a0422020a05")) }
    }

    @Test("A set built with --include_imports reads its last file as the one chosen")
    func includeImports() throws {
        let schema = try ProtobufSchema.parse(BinaryFixture.data(Self.orderDescriptorSet))
        #expect(schema.rootMessages == ["order.Order", "order.Line"])
        #expect(schema.messageNames == ["order.Order", "order.Line", "money.Money"])
        // protoc --encode=order.Order of `id: "A1" total { units: 12 currency: "EUR" } status: DONE`
        #expect(try Self.text("0a0241311207080c12034555521801", schema: schema, message: nil)
            == "id: \"A1\"\ntotal {\n  units: 12\n  currency: \"EUR\"\n}\nstatus: DONE\n")
    }

    @Test("A nested enum in a descriptor set is read once")
    func nestedEnumOnce() throws {
        let files = try ProtobufDescriptorSetParser.parse(BinaryFixture.data(Self.orderDescriptorSet))
        let names = files.flatMap { $0.allEnums.map { $0.fullName } }
        #expect(names == ["order.Order.Status"])
    }

    @Test("A field whose type is a message named optional is not read as a label")
    func optionalAsTypeName() throws {
        let proto = """
            syntax = "proto2";
            package opt;

            message optional {
              optional int32 v = 1;
            }

            message M {
              optional foo = 1;
              repeated optional bar = 2;
            }
            """
        let schema = try ProtobufSchema.parse(Data(proto.utf8))
        // protoc --encode=opt.M of `foo { v: 1 } bar { v: 2 } bar { v: 3 }`, with `foo` declared `optional optional foo = 1;`
        #expect(try Self.text("0a0208011202080212020803", schema: schema, message: "opt.M")
            == "foo {\n  v: 1\n}\nbar {\n  v: 2\n}\nbar {\n  v: 3\n}\n")
    }

    @Test("A verified string that is not UTF-8 refuses the whole value, as protoc does, and an unverified one prints escaped")
    func stringValidation() throws {
        let proto3 = try ProtobufSchema.parse(Data("""
            syntax = "proto3";
            package u;
            message Inner { string s = 1; }
            message M { string s = 1; Inner inner = 2; repeated string r = 3; map<string, int32> m = 4; }
            """.utf8))
        // protoc --decode=u.M fails "contains invalid UTF-8 data" on each of these.
        for fixture in ["0a01ff", "12030a01ff", "1a01ff", "22050a01ff1001", "0a01ff0a0141"] {
            #expect(throws: BinaryValueDecodeError.self, "\(fixture)") {
                try Self.text(fixture, schema: proto3, message: "u.M")
            }
        }
        let proto2 = try ProtobufSchema.parse(Data("syntax = \"proto2\"; message M { optional string s = 1; }".utf8))
        #expect(try Self.text("0a01ff", schema: proto2, message: "M") == "s: \"\\377\"\n")
        let editions = try ProtobufSchema.parse(Data("""
            edition = "2023";
            package ue;
            message M { string s = 1 [features.utf8_validation = NONE]; string v = 2; }
            """.utf8))
        #expect(try Self.text("0a01ff", schema: editions, message: "ue.M") == "s: \"\\377\"\n")
        #expect(throws: BinaryValueDecodeError.self) { try Self.text("1201ff", schema: editions, message: "ue.M") }
    }

    @Test("A declared message or packed field whose bytes do not parse refuses the value, as protoc does")
    func malformedDeclaredFields() throws {
        let schema = try ProtobufSchema.parse(Data("""
            syntax = "proto3";
            package n;
            message Inner { int32 a = 1; }
            message Inner2 { string s = 1; }
            message M { Inner inner = 1; repeated int32 p = 2; Inner2 g = 3; }
            """.utf8))
        // protoc --decode=n.M fails "Failed to parse input." on each of these.
        for fixture in ["0a0108", "1203ffffff", "0a03ff0101"] {
            #expect(throws: BinaryValueDecodeError.self, "\(fixture)") {
                try Self.text(fixture, schema: schema, message: "n.M")
            }
        }
        // protoc --decode=n.M of 1a020801: a wire type the nested field does not declare is only unknown.
        #expect(try Self.text("1a020801", schema: schema, message: "n.M") == "g {\n  1: 1\n}\n")
    }

    @Test("A oneof message member that a later member replaces must still parse, as protoc parses it first")
    func discardedOneofMemberIsParsed() throws {
        let schema = try ProtobufSchema.parse(Data("""
            syntax = "proto3";
            package o2;
            message Inner { int32 n = 1; }
            message M { oneof c { Inner a = 1; int32 b = 2; } }
            """.utf8))
        // protoc --decode=o2.M fails on both: `a` holds a truncated varint.
        for fixture in ["0a01081007", "10070a0108"] {
            #expect(throws: BinaryValueDecodeError.self, "\(fixture)") {
                try Self.text(fixture, schema: schema, message: "o2.M")
            }
        }
        #expect(try Self.text("0a0208011007", schema: schema, message: "o2.M") == "b: 7\n")
    }

    @Test("An editions message field set DELIMITED reads its group framing, from a .proto and a descriptor set")
    func delimitedMessageEncoding() throws {
        let proto = """
            edition = "2023";
            package d;
            message Inner { int32 n = 1; }
            message M { Inner inner = 1 [features.message_encoding = DELIMITED]; Inner plain = 2; }
            """
        // protoc --descriptor_set_out=d.desc of the file above.
        let descriptorSet = "0a7c0a07642e70726f746f12016422150a05496e6e6572120c0a016e18012001280552016e224a0a014d12250a05696e6e6572"
            + "18012001280b32082e642e496e6e65724205aa010228025205696e6e6572121e0a05706c61696e18022001280b32082e642e496e6e"
            + "65725205706c61696e620865646974696f6e7370e807"
        for schema in [try ProtobufSchema.parse(Data(proto.utf8)), try ProtobufSchema.parse(BinaryFixture.data(descriptorSet))] {
            // protoc --decode=d.M of 0b08070c, then of 0a020807 sent length-prefixed.
            #expect(try Self.text("0b08070c", schema: schema, message: "d.M") == "inner {\n  n: 7\n}\n")
            #expect(try Self.text("0a020807", schema: schema, message: "d.M") == "1 {\n  1: 7\n}\n")
        }
        let fileLevel = try ProtobufSchema.parse(Data("""
            edition = "2023";
            package d2;
            option features.message_encoding = DELIMITED;
            message Inner { int32 n = 1; }
            message M { Inner inner = 1; repeated Inner many = 2; }
            """.utf8))
        // protoc --decode=d2.M of 0b08070c1308011413080214
        #expect(try Self.text("0b08070c1308011413080214", schema: fileLevel, message: "d2.M")
            == "inner {\n  n: 7\n}\nmany {\n  n: 1\n}\nmany {\n  n: 2\n}\n")
    }

    @Test("A cell reads no further into a group than its budget, so bytes past it, even broken ones, are never read")
    func groupScanIsBudgeted() throws {
        let schema = try ProtobufSchema.parse(Data("""
            syntax = "proto2";
            package gb;
            message M { optional group Item = 1 { repeated int32 v = 2; } }
            """.utf8))
        // Hand-written: a group of fifty `v: 1`, then a byte that starts no field and no end tag.
        let fixture = "0b" + String(repeating: "1001", count: 50) + "ff"
        let message = try ProtobufSchemaDecoder.decode(BinaryFixture.data(fixture), schema: schema, message: "gb.M", maxValues: 5)
        let text = ProtobufSchemaTextWriter.text(message.fields, multiLine: false)
        #expect(text.hasPrefix("Item { v: 1"))
        #expect(text.hasSuffix("…"))
        #expect(throws: BinaryValueDecodeError.self) {
            try ProtobufSchemaDecoder.decode(BinaryFixture.data(fixture), schema: schema, message: "gb.M")
        }
    }

    @Test("A sint32 wider than 32 bits is cut to 32 before ZigZag, as protoc reads one a sint64 writer sent")
    func wideSint32() throws {
        let schema = try ProtobufSchema.parse(Data("syntax = \"proto3\"; message M { sint32 n = 1; }".utf8))
        // protoc --decode=M of 088280808010
        #expect(try Self.text("088280808010", schema: schema, message: "M") == "n: 1\n")
    }

    @Test("Features written as one aggregate option apply like dotted ones")
    func aggregateFeatures() throws {
        let schema = try ProtobufSchema.parse(Data("""
            edition = "2023";
            package ag;
            option features = { message_encoding: DELIMITED, field_presence: IMPLICIT };
            message Inner { int32 n = 1; }
            message M {
              Inner inner = 1;
              int32 z = 2;
              string t = 3 [features = { utf8_validation: NONE }];
              int32 e = 4 [features = { field_presence: EXPLICIT }];
            }
            """.utf8))
        // protoc --decode=ag.M of 0b08070c10001a01ff2000
        #expect(try Self.text("0b08070c10001a01ff2000", schema: schema, message: "ag.M")
            == "inner {\n  n: 7\n}\nt: \"\\377\"\ne: 0\n")
    }

    @Test("A map entry keeps its last value: a closed enum number it does not declare rejects it only when left standing")
    func mapEntryLastValueWins() throws {
        let schema = try ProtobufSchema.parse(Data("""
            syntax = "proto2";
            package me;
            enum E { A = 0; B = 1; }
            message M { map<int32, E> m = 1; }
            """.utf8))
        // protoc --decode=me.M of 0a06080110091001, then of 0a06080110011009.
        #expect(try Self.text("0a06080110091001", schema: schema, message: "me.M") == "m {\n  key: 1\n  value: B\n}\n")
        #expect(try Self.text("0a06080110011009", schema: schema, message: "me.M") == "1 {\n  1: 1\n  2: 9\n}\n")
    }

    @Test("A map's message values stay length-prefixed in a file that sets DELIMITED")
    func delimitedFileKeepsMapValuesLengthPrefixed() throws {
        let schema = try ProtobufSchema.parse(Data("""
            edition = "2023";
            package dm;
            option features.message_encoding = DELIMITED;
            message Child { int32 n = 1; }
            message M { map<string, Child> m = 1; }
            """.utf8))
        // protoc --decode=dm.M of 0a070a016112020805
        #expect(try Self.text("0a070a016112020805", schema: schema, message: "dm.M")
            == "m {\n  key: \"a\"\n  value {\n    n: 5\n  }\n}\n")
    }

    @Test("Parsing a replaced oneof member spends the cell's budget instead of a fresh one")
    func discardedOneofSpendsBudget() throws {
        let schema = try ProtobufSchema.parse(Data("""
            syntax = "proto3";
            package ob;
            message Inner { repeated int32 v = 1; }
            message M { oneof c { Inner a = 1; int32 b = 2; } }
            """.utf8))
        // Hand-written: `a` holding a hundred unpacked `v: 1`, then `b: 7`.
        let fixture = "0ac801" + String(repeating: "0801", count: 100) + "1007"
        let message = try ProtobufSchemaDecoder.decode(BinaryFixture.data(fixture), schema: schema, message: "ob.M", maxValues: 5)
        #expect(ProtobufSchemaTextWriter.text(message.fields, multiLine: false) == "b: 7")
    }

    @Test("The package qualifies the definitions written before it too")
    func packageAfterMessage() throws {
        let schema = try ProtobufSchema.parse(Data("""
            syntax = "proto2";
            message A { optional B b = 1; }
            package x;
            message B { optional int32 v = 1; }
            """.utf8))
        #expect(schema.messageNames == ["x.A", "x.B"])
        // protoc --decode=x.A of 0a020807
        #expect(try Self.text("0a020807", schema: schema, message: "x.A") == "b {\n  v: 7\n}\n")
    }

    @Test("A .proto file saved with a UTF-8 byte order mark reads as protoc reads it")
    func byteOrderMark() throws {
        let schema = try ProtobufSchema.parse(Data([0xEF, 0xBB, 0xBF]) + Data("syntax = \"proto3\"; message Q { int32 a = 1; }".utf8))
        #expect(try Self.text("0805", schema: schema, message: "Q") == "a: 5\n")
    }

    @Test("A cell spends its budget inside a field the schema does not name")
    func unknownFieldBudget() throws {
        let schema = try ProtobufSchema.parse(Data(Self.budgetProto.utf8))
        // Hand-written: field 9 holding fifty `1: 1`.
        let fixture = "4a64" + String(repeating: "0801", count: 50)
        let message = try ProtobufSchemaDecoder.decode(BinaryFixture.data(fixture), schema: schema, message: "budget.Box", maxValues: 5)
        #expect(ProtobufSchemaTextWriter.text(message.fields, multiLine: false) == "9 { 1: 1 1: 1 1: 1 1: 1 … }")
    }

    @Test("Messages read in field order whatever their wire order, and the budget runs out where it runs out")
    func messagesInFieldOrder() throws {
        let schema = try ProtobufSchema.parse(Data(Self.budgetProto.utf8))
        // protoc --encode=budget.Box of `c { v: 7 v: 8 v: 9 }`, `b { v: 4 v: 5 v: 6 }` and `a { v: 1 v: 2 v: 3 }`, joined.
        let fixture = "1a0608070808080912060804080508060a06080108020803"
        #expect(try Self.text(fixture, schema: schema, message: "budget.Box")
            == "a {\n  v: 1\n  v: 2\n  v: 3\n}\nb {\n  v: 4\n  v: 5\n  v: 6\n}\nc {\n  v: 7\n  v: 8\n  v: 9\n}\n")
        for _ in 0..<5 {
            let message = try ProtobufSchemaDecoder.decode(BinaryFixture.data(fixture), schema: schema, message: "budget.Box", maxValues: 7)
            #expect(ProtobufSchemaTextWriter.text(message.fields, multiLine: false) == "a { v: 1 v: 2 v: 3 } b { v: 4 … } c { … }")
        }
    }

    @Test("A field the schema does not name counts once toward the tree's node limit")
    func unknownFieldsCountOnce() throws {
        let schema = try ProtobufSchema.parse(Data(Self.shopProto.utf8))
        // Hand-written: 3,000 copies of `2: 1`, which shop.Other does not declare.
        let fixture = Data((0..<3_000).flatMap { _ in [UInt8(0x10), 0x01] })
        let message = try ProtobufSchemaDecoder.decode(fixture, schema: schema, message: "shop.Other")
        let root = ProtobufSchemaTreeBuilder.build(from: message, formats: BinaryFixture.english)
        #expect(root.children.count == 3_000)
        #expect(root.children.last?.kind == .varint)
    }
}
