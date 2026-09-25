//
//  ForeignKeyLookupColumnTests.swift
//  TablePro
//

import Foundation
import Testing

@testable import TablePro

/// `supportsPatternMatch` decides both which columns the foreign key picker offers as a label on
/// its own and which ones carry the search. It answers a closed list of character type names,
/// because `ColumnTypeClassifier` files everything it does not recognise under `.text` and a `LIKE`
/// against a `uuid`, an enum or an array is an error on PostgreSQL rather than an empty result.
struct ForeignKeyLookupColumnTests {
    private func column(_ rawType: String?) -> ForeignKeyLookupColumn {
        ForeignKeyLookupColumn(name: "c", type: .text(rawType: rawType))
    }

    @Test("A character type carries a pattern predicate")
    func characterTypesMatch() {
        for rawType in ["TEXT", "VARCHAR(64)", "nvarchar(10)", "CITEXT", "LONGTEXT"] {
            #expect(column(rawType).supportsPatternMatch, "\(rawType) should pattern match")
        }
    }

    @Test("A type the classifier only guessed at carries none")
    func guessedTypesDoNotMatch() {
        for rawType in ["uuid", "inet", "money", "tsvector"] {
            #expect(!column(rawType).supportsPatternMatch, "\(rawType) should not pattern match")
        }
    }

    @Test("A type that is not text carries none")
    func nonTextTypesDoNotMatch() {
        #expect(!ForeignKeyLookupColumn(name: "c", type: .integer(rawType: "INTEGER")).supportsPatternMatch)
        #expect(!ForeignKeyLookupColumn(name: "c", type: .date(rawType: "DATE")).supportsPatternMatch)
        #expect(!ForeignKeyLookupColumn(name: "c", type: .decimal(rawType: "NUMERIC")).supportsPatternMatch)
    }

    /// `create table t(a, b)` is legal SQLite and common in hand-written databases. Measured on
    /// 3.54.0: `PRAGMA table_xinfo` answers a zero-length type for such a column, and `LIKE`
    /// against it works. Reading the empty type as unknown left every column of that table
    /// unlabelled and unsearchable, with the picker listing bare keys and no way to say why.
    @Test("A column the engine declared with no type carries a predicate")
    func undeclaredTypeMatches() {
        #expect(column("").supportsPatternMatch)
        #expect(column("   ").supportsPatternMatch)
        #expect(column("").declaresNoType)
        #expect(column("   ").declaresNoType)
    }

    /// Several of the app's own conversions build a column with no type information at all. That
    /// is not an engine saying "this column has no declared type", and it must not become a
    /// predicate on a strict engine.
    @Test("A column with no type information at all is left alone")
    func missingTypeIsNotAnUndeclaredType() {
        #expect(!column(nil).supportsPatternMatch)
        #expect(!column(nil).declaresNoType)
    }

    @Test("A declared type is still reported for display, and an empty one is not")
    func displayTypeNameFollowsTheDeclaration() {
        #expect(column("TEXT").displayTypeName == "TEXT")
        #expect(column("").displayTypeName == nil)
        #expect(column(nil).displayTypeName == nil)
    }

    /// The reporter's shape: a parent whose every column is untyped had no label to offer.
    @Test("An untyped table offers its first non-key column as a label")
    func untypedTableStillGetsALabel() {
        let columns = [
            ForeignKeyLookupColumn(name: "marchio", type: .text(rawType: "")),
            ForeignKeyLookupColumn(name: "nome", type: .text(rawType: "")),
        ]
        let resolved = ForeignKeyLabelColumn.resolve(
            columns: columns, keyColumn: "marchio", choice: .unset
        )
        #expect(resolved.map(\.name) == ["nome"])
    }
}
