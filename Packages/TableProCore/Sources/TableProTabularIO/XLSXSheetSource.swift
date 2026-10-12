import Foundation

public struct XLSXSheetSource: TabularSource {
    struct Layout: Sendable {
        let rowCount: Int
        let firstRowIndex: Int
        let firstColumnIndex: Int
        let mergedRanges: [XLSXCellRange]
    }

    private enum RenderedCell {
        case absent
        case external(UnsafeBufferPointer<UInt8>, TabularCellKind)
        case scratch(TabularCellKind)
    }

    public let name: String
    public let rowCount: Int
    public let firstRowIndex: Int
    public let firstColumnIndex: Int
    public let mergedRanges: [XLSXCellRange]
    public let dateSystem: XLSXDateSystem
    private let columns: [XLSXColumnStore]
    private let arena: XLSXByteHeap
    private let sharedStrings: XLSXSharedStrings

    init(
        name: String,
        layout: Layout,
        columns: [XLSXColumnStore],
        arena: XLSXByteHeap,
        sharedStrings: XLSXSharedStrings,
        dateSystem: XLSXDateSystem
    ) {
        self.name = name
        self.rowCount = layout.rowCount
        self.firstRowIndex = layout.firstRowIndex
        self.firstColumnIndex = layout.firstColumnIndex
        self.mergedRanges = layout.mergedRanges
        self.columns = columns
        self.arena = arena
        self.sharedStrings = sharedStrings
        self.dateSystem = dateSystem
    }

    public var columnCount: Int { columns.count }

    public var intrinsicColumnNames: [String]? { nil }

    public var absentCell: TabularCell { .text("") }

    public var firstRowLooksLikeHeader: Bool {
        TabularHeaderHeuristic.firstRowLooksLikeHeader(of: self)
    }

    public func sheetReference(row: Int, column: Int) -> XLSXCellReference {
        XLSXCellReference(row: firstRowIndex + row, column: firstColumnIndex + column)
    }

    public func cell(row: Int, column: Int) -> TabularCell {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return absentCell }
        let store = columns[column]
        var hint = 0
        guard let slot = store.slot(forRow: row, hint: &hint) else { return absentCell }
        var scratch: [UInt8] = []
        switch render(kind: store.kinds[slot], payload: store.payloads[slot], scratch: &scratch) {
        case .absent:
            return absentCell
        case .external(let bytes, let kind):
            return TabularCell(kind: kind, text: TabularTextCodec.string(from: bytes, encoding: .utf8))
        case .scratch(let kind):
            let text = scratch.withUnsafeBufferPointer { TabularTextCodec.string(from: $0, encoding: .utf8) }
            return TabularCell(kind: kind, text: text)
        }
    }

    public func cells(row: Int) -> [TabularCell] {
        guard row >= 0, row < rowCount else { return [] }
        return (0..<columnCount).map { cell(row: row, column: $0) }
    }

    public func scan<Rows: Collection>(
        columns requested: [Int],
        rows: Rows,
        _ body: (Int, TabularRowCells) -> Bool
    ) where Rows.Element == Int {
        guard !requested.isEmpty else { return }
        var buffer = TabularCellBuffer()
        var scratch: [UInt8] = []
        var hints = [Int](repeating: -1, count: requested.count)
        for row in rows {
            guard row >= 0, row < rowCount else { continue }
            buffer.reset(slots: requested.count, fill: .text)
            for (slot, column) in requested.enumerated() where column >= 0 && column < columnCount {
                let store = columns[column]
                guard let index = store.slot(forRow: row, hint: &hints[slot]) else { continue }
                scratch.removeAll(keepingCapacity: true)
                switch render(kind: store.kinds[index], payload: store.payloads[index], scratch: &scratch) {
                case .absent:
                    continue
                case .external(let bytes, let kind):
                    buffer.setExternal(slot, bytes, kind: kind)
                case .scratch(let kind):
                    scratch.withUnsafeBufferPointer { buffer.setCopy(slot, $0, kind: kind) }
                }
            }
            let keepGoing = buffer.withResolved { body(row, $0) }
            if !keepGoing { return }
        }
    }

    private func render(kind: UInt8, payload: UInt64, scratch: inout [UInt8]) -> RenderedCell {
        let tabularKind = XLSXStoredCell.tabularKind(of: kind)
        if XLSXStoredCell.isDecimal(kind) {
            XLSXDecimal.append(
                mantissa: Int64(bitPattern: payload),
                scale: Int(kind - XLSXStoredCell.decimalBase),
                to: &scratch
            )
            return .scratch(tabularKind)
        }
        if XLSXStoredCell.usesArena(kind) {
            return .external(arena.bytes(at: payload), tabularKind)
        }
        switch kind {
        case XLSXStoredCell.sharedString:
            guard let bytes = sharedStrings.bytes(at: Int(payload)) else { return .absent }
            return .external(bytes, tabularKind)
        case XLSXStoredCell.booleanTrue:
            scratch.append(contentsOf: "TRUE".utf8)
            return .scratch(tabularKind)
        case XLSXStoredCell.booleanFalse:
            scratch.append(contentsOf: "FALSE".utf8)
            return .scratch(tabularKind)
        case XLSXStoredCell.durationSerial:
            dateSystem.appendElapsedText(forSerial: Double(bitPattern: payload), to: &scratch)
            return .scratch(tabularKind)
        case XLSXStoredCell.dateSerial, XLSXStoredCell.timeSerial:
            dateSystem.appendISOText(
                forSerial: Double(bitPattern: payload),
                timeOnly: kind == XLSXStoredCell.timeSerial,
                to: &scratch
            )
            return .scratch(tabularKind)
        default:
            return .absent
        }
    }
}
