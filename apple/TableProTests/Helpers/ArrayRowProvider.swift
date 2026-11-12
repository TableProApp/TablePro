@testable import TablePro

final class ArrayRowProvider: DataRowProviding {
    private let rows: [DataRow]
    private let rowLimit: Int?
    private let holdsRowPastTheLimit: Bool
    private var index = 0

    init(rows: [DataRow], rowLimit: Int? = nil) {
        self.rows = rowLimit.map { Array(rows.prefix($0)) } ?? rows
        self.rowLimit = rowLimit
        self.holdsRowPastTheLimit = rowLimit.map { rows.count > $0 } ?? false
    }

    var endedAtRowLimit: Bool {
        guard let rowLimit, index >= rows.count else { return false }
        return holdsRowPastTheLimit && rows.count >= rowLimit
    }

    func nextRow() async throws -> DataRow? {
        guard index < rows.count else { return nil }
        defer { index += 1 }
        return rows[index]
    }

    func drain() async throws {
        index = rows.count
    }
}
