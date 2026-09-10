import Foundation
import TableProModels
import TableProPluginKit
import Testing

@testable import TableProMobile

/// iOS links its drivers directly, so it cannot ask a plugin bundle for its SQL dialect the way the
/// Mac does. `SQLBuilder` carries a hand-written table instead, and nothing forced that table to
/// keep up with the drivers beside it: DuckDB shipped with no arm at all and fell through to the
/// default, which is not a neutral fallback.
@Suite("SQL dialect parity")
struct SQLDialectParityTests {
    /// `SQLDialectDescriptor` defaults `caseSensitivityStyle` to `.unsupported`, and
    /// `PluginSQLCaseFolding.resolve` turns that into plain `LIKE` with no folding, while
    /// `isAdjustable` returns false so the case sensitivity control is never offered. A missing arm
    /// therefore does not fail loudly: the filter runs, returns fewer rows than the same filter on
    /// the Mac, and offers no way to change it.
    @Test("Every SQL type iOS ships resolves a real case sensitivity style")
    func everySupportedSQLTypeHasADialect() {
        for type in IOSDriverFactory().supportedTypes() where type != .redis {
            #expect(
                SQLBuilder.caseSensitivityStyle(for: type) != .unsupported,
                "\(type.rawValue) has no arm in SQLBuilder.dialectDescriptor, so its filters fall back to case-sensitive LIKE"
            )
        }
    }

    /// Redis is excluded above rather than overlooked: `RedisPlugin.sqlDialect` is `nil` on the Mac
    /// too, because Redis is not queried with SQL.
    @Test("DuckDB matches what its plugin declares on the Mac")
    func duckDBMatchesThePlugin() {
        #expect(SQLBuilder.caseSensitivityStyle(for: .duckdb) == .ilikeOperator)
    }

    /// The styles the Mac's plugins declare, so a change on one platform that is not made on the
    /// other is caught here rather than by a user seeing different rows on their phone.
    @Test("Each type keeps the style its Mac plugin declares")
    func stylesMatchTheMacPlugins() {
        let expected: [(DatabaseType, SQLDialectDescriptor.CaseSensitivityStyle)] = [
            (.sqlite, .collationDefined),
            (.mysql, .collationDefined),
            (.mariadb, .collationDefined),
            (.mssql, .collationDefined),
            (.postgresql, .ilikeOperator),
            (.duckdb, .ilikeOperator),
            (.redshift, .caseFoldFunction),
            (.oracle, .caseFoldFunction)
        ]
        for (type, style) in expected {
            #expect(
                SQLBuilder.caseSensitivityStyle(for: type) == style,
                "\(type.rawValue) should resolve \(style.rawValue)"
            )
        }
    }
}
