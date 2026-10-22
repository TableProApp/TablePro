import Foundation
import TableProModels
import TableProPluginKit
import Testing

@testable import TableProMobile

// DuckDB once shipped with no arm here and fell to the default, which is not a neutral fallback.
@Suite("SQL dialect parity")
struct SQLDialectParityTests {
    // A missing arm fails quietly: plain LIKE with no folding, fewer rows than on the Mac, and no Match Case control.
    @Test("Every SQL type iOS ships resolves a real case sensitivity style")
    func everySupportedSQLTypeHasADialect() {
        for type in IOSDriverFactory().supportedTypes() where type.speaksSQL {
            #expect(
                SQLBuilder.caseSensitivityStyle(for: type) != .unsupported,
                "\(type.rawValue) has no arm in SQLBuilder.dialectDescriptor, so its filters fall back to case-sensitive LIKE"
            )
        }
    }

    @Test("DuckDB matches what its plugin declares on the Mac")
    func duckDBMatchesThePlugin() {
        #expect(SQLBuilder.caseSensitivityStyle(for: .duckdb) == .ilikeOperator)
    }

    @Test("Each type keeps the style its Mac plugin declares")
    func stylesMatchTheMacPlugins() {
        let expected: [(DatabaseType, SQLDialectDescriptor.CaseSensitivityStyle)] = [
            (.sqlite, .collationDefined),
            (.mysql, .collationDefined),
            (.mariadb, .collationDefined),
            (.tidb, .collationDefined),
            (.oceanbase, .collationDefined),
            (.mssql, .collationDefined),
            (.postgresql, .ilikeOperator),
            (.duckdb, .ilikeOperator),
            (.redshift, .caseFoldFunction),
            (.oracle, .caseFoldFunction),
            (.clickhouse, .caseFoldFunction),
            (.mongodb, .driverManaged)
        ]
        for (type, style) in expected {
            #expect(
                SQLBuilder.caseSensitivityStyle(for: type) == style,
                "\(type.rawValue) should resolve \(style.rawValue)"
            )
        }
    }
}
