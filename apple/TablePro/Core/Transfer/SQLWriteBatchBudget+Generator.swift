import Foundation

extension SQLWriteBatchBudget {
    init(
        columnCount: Int,
        generator: SQLStatementGenerator,
        maxBytes: Int = SQLWriteBatchBudget.maximumBytes
    ) {
        self.init(columnCount: columnCount, statements: generator.importStatements, maxBytes: maxBytes)
    }
}
