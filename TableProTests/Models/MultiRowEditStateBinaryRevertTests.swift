//
//  MultiRowEditStateBinaryRevertTests.swift
//  TableProTests
//
//  A binary field holds its bytes one character per byte. Restoring the stored value as text
//  staged that string over the blob, and SQLite cut it at the first NUL.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct MultiRowEditStateBinaryRevertTests {
    private static let wkbPoint = Data(
        [0x01, 0x01, 0x00, 0x00, 0x00] + [0, 0, 0, 0, 0, 0, 0xF0, 0x3F] + [0, 0, 0, 0, 0, 0, 0, 0x40]
    )
    /// Every byte value, NUL first.
    private static let everyByte = Data((0 ... 255).map { UInt8($0) })

    /// The handoff the main window does: the typed cells decide which columns are binary, and the
    /// fields get each cell as text, bytes as one character per byte.
    private func makeSUT(cells: [[PluginCellValue]], columnTypes: [ColumnType]) -> MultiRowEditState {
        let sut = MultiRowEditState()
        let rows: [[String?]] = cells.map { row in
            row.map { cell -> String? in
                switch cell {
                case .null: return nil
                case .text(let text): return text
                case .bytes(let data): return String(data: data, encoding: .isoLatin1) ?? ""
                }
            }
        }
        sut.configure(
            selectedRowIndices: Set(cells.indices),
            rowIDs: cells.indices.map { RowID.existing($0) },
            allRows: rows,
            columns: columnTypes.indices.map { "c\($0)" },
            columnTypes: columnTypes,
            binaryColumns: MultiRowEditState.binaryColumns(in: cells)
        )
        return sut
    }

    /// What Clear in the field's menu does: put the field's own original value back.
    private func clear(_ sut: MultiRowEditState, at index: Int) {
        sut.updateField(at: index, value: sut.fields[index].originalValue ?? "")
    }

    @Test("Clearing Set NULL on a binary field sends the stored bytes back")
    func clearingNullOnABinaryFieldSendsItsBytes() {
        let cases: [(stored: Data, type: ColumnType)] = [
            (Self.wkbPoint, .spatial(rawType: "POINT")),
            (Self.everyByte, .blob(rawType: "BLOB"))
        ]
        for (stored, type) in cases {
            let sut = makeSUT(cells: [[.bytes(stored)]], columnTypes: [type])
            var sent: [PluginCellValue] = []
            sut.onFieldChanged = { _, value, _ in sent.append(value) }

            sut.setFieldToNull(at: 0)
            clear(sut, at: 0)

            #expect(sent == [.null, .bytes(stored)], "\(type)")
            #expect(sut.fields[0].hasEdit == false, "\(type)")
        }
    }

    @Test("Clearing a binary field whose rows disagree sends each row its own bytes")
    func revertingABinaryColumnSendsEachRowsBytes() {
        let sut = makeSUT(
            cells: [[.bytes(Self.wkbPoint)], [.bytes(Self.everyByte)], [.null]],
            columnTypes: [.spatial(rawType: "POINT")]
        )
        var reverted: [RowID: PluginCellValue] = [:]
        sut.onFieldReverted = { _, values, _ in reverted = values }

        sut.setFieldToNull(at: 0)
        clear(sut, at: 0)

        #expect(reverted == [
            .existing(0): .bytes(Self.wkbPoint),
            .existing(1): .bytes(Self.everyByte),
            .existing(2): .null
        ])
        #expect(sut.fields[0].hasEdit == false)
    }

    @Test("Set EMPTY back onto an empty blob sends empty bytes")
    func setEmptyBackOntoAnEmptyBlobSendsBytes() {
        let sut = makeSUT(cells: [[.bytes(Data())]], columnTypes: [.blob(rawType: "BLOB")])
        var sent: [PluginCellValue] = []
        sut.onFieldChanged = { _, value, _ in sent.append(value) }

        sut.setFieldToNull(at: 0)
        sut.setFieldToEmpty(at: 0)

        #expect(sent == [.null, .bytes(Data())])
        #expect(sut.fields[0].hasEdit == false)
    }

    @Test("A text field still reverts as text")
    func textFieldRevertsAsText() {
        let sut = makeSUT(
            cells: [[.text("Alice"), .text("a")], [.text("Alice"), .text("b")]],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        var sent: [PluginCellValue] = []
        var reverted: [RowID: PluginCellValue] = [:]
        sut.onFieldChanged = { _, value, _ in sent.append(value) }
        sut.onFieldReverted = { _, values, _ in reverted = values }

        sut.setFieldToNull(at: 0)
        clear(sut, at: 0)
        sut.setFieldToNull(at: 1)
        clear(sut, at: 1)

        #expect(sent == [.null, .text("Alice"), .null])
        #expect(reverted == [.existing(0): .text("a"), .existing(1): .text("b")])
    }

    @Test("A value typed into a binary field is sent as typed")
    func typedValueOnABinaryFieldStaysText() {
        let sut = makeSUT(cells: [[.bytes(Self.wkbPoint)]], columnTypes: [.blob(rawType: "BLOB")])
        var sent: [PluginCellValue] = []
        sut.onFieldChanged = { _, value, _ in sent.append(value) }

        sut.updateField(at: 0, value: "replaced")

        #expect(sent == [.text("replaced")])
    }
}
