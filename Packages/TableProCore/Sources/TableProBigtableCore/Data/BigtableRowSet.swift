import Foundation

/// Rows laid out for the grid: `_key` first, then one column per `family:qualifier` any row on the
/// page holds, in family then qualifier order. A cell a row does not have is reported absent.
public struct BigtableRowSet: Sendable, Equatable {
    public static let keyColumn = "_key"

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

    /// A value that is not text goes to the grid as bytes, so it shows as hex and an edit of
    /// another cell in the row cannot rewrite it as a string.
    static func cell(_ value: Data) -> Cell {
        if let text = String(data: value, encoding: .utf8), BigtableBytes.isPrintable(text) {
            return .text(text)
        }
        return .bytes(value)
    }
}
