import Foundation

/// Rows laid out for the grid: `_key` first, then one column per `family:qualifier` any row on the
/// page holds, in family then qualifier order.
public struct BigtableRowSet: Sendable, Equatable {
    public static let keyColumn = "_key"
    public static let extraColumn = "__extra__"

    public enum Cell: Sendable, Equatable {
        case absent
        case text(String)
        case bytes(Data)
    }

    public let columns: [String]
    public let rows: [[Cell]]
    public let locators: [String]
    public let absentCells: [Int: Set<Int>]

    public init(rows input: [BigtableRow]) {
        let ordered = Set(input.flatMap { $0.cells.keys }).sorted()
        var rows: [[Cell]] = []
        var absent: [Int: Set<Int>] = [:]
        rows.reserveCapacity(input.count)
        for (rowIndex, row) in input.enumerated() {
            var cells: [Cell] = [.text(BigtableBytes.display(row.key))]
            for (offset, column) in ordered.enumerated() {
                guard let cell = row.cells[column] else {
                    cells.append(.absent)
                    absent[rowIndex, default: []].insert(offset + 1)
                    continue
                }
                cells.append(Self.cell(cell.value))
            }
            rows.append(cells)
        }
        self.columns = [Self.keyColumn] + ordered.map(\.name)
        self.rows = rows
        self.locators = input.map { $0.key.base64EncodedString() }
        self.absentCells = absent
    }

    /// A value that is not text, or text a write would read back as base64, goes to the grid as
    /// bytes, so writing it back reproduces the same bytes.
    static func cell(_ value: Data) -> Cell {
        BigtableBytes.printableText(value).map(Cell.text) ?? .bytes(value)
    }

    /// The page under `header`, the columns an export fixed from its first page, with `__extra__`
    /// last. Cells of any column the header lacks go into `__extra__` as one JSON object.
    public func rows(alignedTo header: [String]) -> [[Cell]] {
        rows.map { row in
            var byName: [String: Cell] = [:]
            for (column, cell) in zip(columns, row) where cell != .absent {
                byName[column] = cell
            }
            var aligned = header.filter { $0 != Self.extraColumn }.map { byName.removeValue(forKey: $0) ?? .absent }
            aligned.append(Self.extraCell(byName))
            return aligned
        }
    }

    private static func extraCell(_ cells: [String: Cell]) -> Cell {
        let extra = cells.compactMapValues { cell -> String? in
            switch cell {
            case .absent: return nil
            case .text(let text): return text
            case .bytes(let data): return BigtableBytes.base64Prefix + data.base64EncodedString()
            }
        }
        guard !extra.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return .absent
        }
        return .text(text)
    }
}
