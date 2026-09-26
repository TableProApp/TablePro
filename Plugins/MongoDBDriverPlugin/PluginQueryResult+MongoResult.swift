import Foundation
import TableProPluginKit

/// The copies the MongoDB driver makes of a result on its way to the grid.
///
/// Every copy goes through `rebuilt`, which carries the column metadata, the timing and the row
/// locators across. Rebuilding field by field is how a copy used to drop the timing, and dropping
/// the locators would leave every row of a table uneditable without a word.
extension PluginQueryResult {
    func withRowsAffected(_ count: Int) -> PluginQueryResult {
        guard count != rowsAffected else { return self }
        return rebuilt(rowsAffected: count)
    }

    func withStatus(_ message: String) -> PluginQueryResult {
        rebuilt(statusMessage: message)
    }

    /// Locators that do not pair one to one with the rows are dropped rather than trusted.
    func withRowLocators(_ locators: [String?]?) -> PluginQueryResult {
        var result = self
        result.rowLocators = locators?.count == rows.count ? locators : nil
        return result
    }

    /// The first `rowCap` rows, marked truncated.
    func capped(to rowCap: Int) -> PluginQueryResult {
        guard rows.count > rowCap else { return self }
        var result = rebuilt(rows: Array(rows.prefix(max(rowCap, 0))), isTruncated: true)
        result.rowLocators = rowLocators.map { Array($0.prefix(max(rowCap, 0))) }
        return result
    }

    private func rebuilt(
        rows: [[PluginCellValue]]? = nil,
        rowsAffected: Int? = nil,
        isTruncated: Bool? = nil,
        statusMessage: String? = nil
    ) -> PluginQueryResult {
        var result = PluginQueryResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows ?? self.rows,
            rowsAffected: rowsAffected ?? self.rowsAffected,
            timing: timing,
            isTruncated: isTruncated ?? self.isTruncated,
            statusMessage: statusMessage ?? self.statusMessage,
            columnMeta: columnMeta
        )
        result.rowLocators = rowLocators
        return result
    }
}
