import Foundation
@testable import TableProOracleCore
import Testing

struct OracleJDWPDebugInfoTests {
    private let sizes = OracleJDWPIDSizes.oracle

    private func body(_ packet: Data) throws -> Data {
        let decoded = try #require(try OracleJDWPPacket.decode(from: packet))
        guard case let .reply(_, _, data) = decoded.packet else { throw OracleJDWPError.malformedPacket }
        return data
    }

    @Test func testRecordedMethodsListOverloadsWithTheirSignatures() throws {
        let methods = try OracleJDWPMethod.decodeList(try body(OracleJDWPRecording.methodsReply), sizes: sizes)
        #expect(methods.map(\.name) == ["<clinit>", "ADD_TAX", "RUN", "ADD_TAX"])
        #expect(methods.map(\.id) == [3, 4, 5, 6])
        #expect(methods[1].argumentTypeNames == ["NUMBER"])
        #expect(methods[3].argumentTypeNames == ["NUMBER", "NUMBER"])
        #expect(!methods[0].isSubprogram)
        #expect(methods[2].isSubprogram)
    }

    // ADD_TAX's table from the live run: lines 3, 5, 6, 7, 8, code index equal to the line.
    @Test func testRecordedLineTableMapsLinesAndIndexes() throws {
        let table = try OracleJDWPLineTable.decode(try body(OracleJDWPRecording.lineTableReply), sizes: sizes)
        #expect(table.start == 3)
        #expect(table.end == 8)
        #expect(table.lines == [3, 5, 6, 7, 8])
        #expect(table.line(at: 6) == 6)
        #expect(table.location(atOrAfter: 4)?.line == 5)
        #expect(table.location(atOrAfter: 6)?.index == 6)
        #expect(table.location(atOrAfter: 9) == nil)
        #expect(table.covers(line: 4))
        #expect(!table.covers(line: 9))
    }

    @Test func testAUnitWithoutDebugInformationHasEmptyLineTables() {
        let table = OracleJDWPLineTable(start: 0, end: 0, entries: [])
        #expect(table.isEmpty)
        #expect(table.location(atOrAfter: 1) == nil)
        #expect(!OracleJDWPMethod(id: 1, name: "<procedure$0>", signature: "()V").isSubprogram)
    }

    // RUN's table: I is declared by the loop at line 13 and lives three lines.
    @Test func testVariableScopeFollowsTheTable() throws {
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.i32(1)
        writer.i32(3)
        for (index, name, signature, length, slot) in [
            (Int64(9), "P_N", "L$Oracle/Builtin/PLS_INTEGER;", Int32(9), Int32(0)),
            (9, "_return", "L$Oracle/Builtin/NUMBER;", 1, 1),
            (13, "I", "L$Oracle/Builtin/PLS_INTEGER;", 3, 2)
        ] {
            writer.i64(index)
            writer.string(name)
            writer.string(signature)
            writer.i32(length)
            writer.i32(slot)
        }
        let variables = try OracleJDWPVariable.decodeTable(writer.data, sizes: sizes)
        #expect(variables.map(\.isArgument) == [true, false, false])
        #expect(variables.map(\.isUserVariable) == [true, false, true])
        #expect(!variables[2].isVisible(at: 9))
        #expect(variables[2].isVisible(at: 14))
        #expect(!variables[2].isVisible(at: 16))
        #expect(variables[0].isVisible(at: 17))
    }

    @Test func testValueShapesFollowTheWrapperFields() {
        let number = [
            OracleJDWPField(id: 1, name: "_value", signature: "Ljava/lang/String;", modifiers: 1),
            OracleJDWPField(id: 2, name: "_canBeNull", signature: "Z", modifiers: 1)
        ]
        #expect(OracleDebugValueShape(fields: number) == .scalar(valueField: 1))
        let record = [
            OracleJDWPField(id: 3, name: "A", signature: "L$Oracle/Builtin/NUMBER;", modifiers: 1),
            OracleJDWPField(id: 4, name: "B", signature: "L$Oracle/Builtin/VARCHAR2;", modifiers: 1),
            OracleJDWPField(id: 5, name: "_type", signature: "Ljava/lang/String;", modifiers: 1)
        ]
        #expect(OracleDebugValueShape(fields: record) == .record(members: Array(record.prefix(2))))
        let collection = [
            OracleJDWPField(id: 7, name: "_values", signature: "[L$Oracle/Function/PROBE/F_CALC/F_CALC/T_NUMS$element;", modifiers: 17),
            OracleJDWPField(id: 10, name: "_type", signature: "Ljava/lang/String;", modifiers: 25)
        ]
        #expect(OracleDebugValueShape(fields: collection) == .collection(valuesField: 7))
        #expect(OracleDebugValueShape(fields: []) == .opaque)
    }
}
