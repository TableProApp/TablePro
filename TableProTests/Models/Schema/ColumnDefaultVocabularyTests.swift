//
//  ColumnDefaultVocabularyTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

@Suite("Column default vocabulary")
struct ColumnDefaultVocabularyTests {
    private func sqlValues(_ type: DatabaseType) -> [String] {
        ColumnDefaultVocabulary.options(for: type).compactMap(\.sql)
    }

    private func titles(_ type: DatabaseType) -> [String] {
        ColumnDefaultVocabulary.options(for: type).compactMap { option in
            switch option {
            case .value(let title, _), .clear(let title), .custom(let title): title
            case .sectionHeader: nil
            }
        }
    }

    @Test("Every engine offers no-default, NULL and a way out to a custom value")
    func headAndTailAreAlwaysPresent() {
        for type in [DatabaseType.mysql, .postgresql, .sqlite, .oracle, .mssql, .clickhouse, .trino] {
            let options = ColumnDefaultVocabulary.options(for: type)
            #expect(options.first == .clear(title: "No default"), "\(type.rawValue)")
            #expect(options.contains(.value(title: "NULL", sql: "NULL")), "\(type.rawValue)")
            #expect(options.last == .custom(title: "Custom…"), "\(type.rawValue)")
        }
    }

    /// `DatabaseType` is open, so a plugin the app has never heard of has to land somewhere honest
    /// rather than inherit another engine's spelling of "now".
    @Test("An unknown engine gets the shared literals and no expressions")
    func unknownEngineGetsLiteralsOnly() {
        let options = ColumnDefaultVocabulary.options(for: DatabaseType(rawValue: "SomeFuturePlugin"))
        #expect(!options.contains { if case .sectionHeader = $0 { return true } else { return false } })
        #expect(sqlValues(DatabaseType(rawValue: "SomeFuturePlugin")) == ["NULL", "''"])
        #expect(options.last == .custom(title: "Custom…"))
    }

    /// Oracle treats a zero-length character value as null, so the two items would be one statement.
    @Test("Empty string is absent exactly where the engine has no such value")
    func emptyStringOmittedOnOracleFamily() {
        #expect(!sqlValues(.oracle).contains("''"))
        #expect(!sqlValues(.dameng).contains("''"))
        #expect(sqlValues(.mysql).contains("''"))
        #expect(sqlValues(.postgresql).contains("''"))
    }

    /// AUTO_INCREMENT is a column attribute on MySQL, a sequence or identity on PostgreSQL and a
    /// primary-key constraint on SQLite. It is a DEFAULT on none of them, and TablePro already
    /// models it as its own structure field.
    @Test("No engine offers AUTO_INCREMENT as a default")
    func autoIncrementIsNeverADefault() {
        for type in DatabaseType.allKnownTypes + [.mysql, .postgresql, .sqlite, .mssql, .oracle] {
            let values = sqlValues(type).map { $0.uppercased() }
            #expect(!values.contains { $0.contains("AUTO_INCREMENT") || $0.contains("AUTOINCREMENT") })
        }
    }

    @Test("Each engine spells the current timestamp its own way")
    func currentTimestampSpelling() {
        #expect(sqlValues(.mysql).contains("CURRENT_TIMESTAMP"))
        #expect(sqlValues(.postgresql).contains("now()"))
        #expect(sqlValues(.clickhouse).contains("now()"))
        #expect(!sqlValues(.clickhouse).contains("CURRENT_TIMESTAMP"))
        #expect(sqlValues(.mssql).contains("GETDATE()"))
        #expect(sqlValues(.oracle).contains("SYSTIMESTAMP"))
        #expect(sqlValues(.snowflake).contains("CURRENT_TIMESTAMP()"))
    }

    /// SQLite's grammar needs the parentheses and PostgreSQL's rejects them, so the two lists cannot
    /// be one list.
    @Test("An expression carries the parentheses its own engine requires")
    func parenthesesFollowTheEngine() {
        #expect(sqlValues(.sqlite).contains("(datetime('now'))"))
        #expect(sqlValues(.mysql).contains("(UUID())"))
        #expect(sqlValues(.mariadb).contains("uuid()"))
        #expect(sqlValues(.postgresql).contains("gen_random_uuid()"))
    }

    /// One plugin serves each of these pairs, so a vocabulary keyed by plugin would give both halves
    /// the same list and half of them a function the server does not have.
    @Test("Engines that share a plugin still get their own vocabulary")
    func sharedPluginsDoNotShareVocabulary() {
        #expect(!sqlValues(.redshift).contains("gen_random_uuid()"))
        #expect(sqlValues(.cockroachdb).contains("unique_rowid()"))
        #expect(!sqlValues(.postgresql).contains("unique_rowid()"))
        #expect(sqlValues(.mysql) != sqlValues(.mariadb))
    }

    @Test("Every entry a menu can choose carries SQL, and the labels are not raw SQL twice")
    func labelsAndValues() {
        let options = ColumnDefaultVocabulary.options(for: .postgresql)
        for option in options {
            if case .value(let title, let sql) = option {
                #expect(!title.isEmpty)
                #expect(!sql.isEmpty)
            }
        }
        #expect(titles(.postgresql).contains("Empty string"))
        #expect(!titles(.postgresql).contains("''"))
    }
}
