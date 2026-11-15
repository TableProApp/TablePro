import Foundation
import TableProPluginKit

extension ImportTargetValues {
    init(
        columns: [(name: String, typeName: String, isGenerated: Bool)],
        databaseType: DatabaseType,
        binaryText: ImportBinaryText?
    ) {
        // MySQL strict mode refuses `true` for an integer flag, SQL Server refuses `yes` for a bit, and SQLite keeps either as text.
        let writesNumericBooleans = (try? resolveSQLDialect(for: databaseType))?.booleanLiteralStyle == .numeric
        self.init(
            columns: columns,
            databaseTypeId: databaseType.rawValue,
            writesNumericBooleans: writesNumericBooleans,
            binaryText: binaryText
        )
    }
}
