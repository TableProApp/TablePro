import Foundation
import Testing
@testable import TableProMobile

@Suite("ColumnMetadataRules")
struct ColumnMetadataRulesTests {
    @Test("MySQL reports an auto-increment column from Extra")
    func mySQLAutoIncrement() {
        #expect(ColumnMetadataRules.mySQLIsAutoIncrement(extra: "auto_increment"))
        #expect(ColumnMetadataRules.mySQLIsAutoIncrement(extra: "AUTO_INCREMENT"))
        #expect(!ColumnMetadataRules.mySQLIsAutoIncrement(extra: ""))
        #expect(!ColumnMetadataRules.mySQLIsAutoIncrement(extra: nil))
    }

    @Test("MySQL DEFAULT_GENERATED is a default, not a generated column")
    func mySQLDefaultGeneratedIsNotGenerated() {
        #expect(!ColumnMetadataRules.mySQLIsGenerated(extra: "DEFAULT_GENERATED"))
        #expect(!ColumnMetadataRules.mySQLIsGenerated(extra: "DEFAULT_GENERATED on update CURRENT_TIMESTAMP"))
    }

    @Test("MySQL reports virtual and stored generated columns")
    func mySQLGenerated() {
        #expect(ColumnMetadataRules.mySQLIsGenerated(extra: "STORED GENERATED"))
        #expect(ColumnMetadataRules.mySQLIsGenerated(extra: "VIRTUAL GENERATED"))
        #expect(!ColumnMetadataRules.mySQLIsGenerated(extra: "auto_increment"))
    }

    @Test("PostgreSQL reports identity columns and serial defaults")
    func postgresAutoIncrement() {
        #expect(ColumnMetadataRules.postgresIsAutoIncrement(isIdentity: "YES", columnDefault: nil))
        #expect(ColumnMetadataRules.postgresIsAutoIncrement(
            isIdentity: "NO", columnDefault: "nextval('t_id_seq'::regclass)"
        ))
        #expect(!ColumnMetadataRules.postgresIsAutoIncrement(isIdentity: "NO", columnDefault: "now()"))
        #expect(!ColumnMetadataRules.postgresIsAutoIncrement(isIdentity: nil, columnDefault: nil))
    }

    @Test("PostgreSQL reports a generated column only when is_generated is ALWAYS")
    func postgresGenerated() {
        #expect(ColumnMetadataRules.postgresIsGenerated(isGenerated: "ALWAYS"))
        #expect(!ColumnMetadataRules.postgresIsGenerated(isGenerated: "NEVER"))
        #expect(!ColumnMetadataRules.postgresIsGenerated(isGenerated: nil))
    }

    @Test("SQLite reports pk as a rank, so every member of a composite key is a primary key")
    func sqlitePrimaryKeyRank() {
        #expect(ColumnMetadataRules.sqliteIsPrimaryKey(pk: "1"))
        #expect(ColumnMetadataRules.sqliteIsPrimaryKey(pk: "2"))
        #expect(!ColumnMetadataRules.sqliteIsPrimaryKey(pk: "0"))
        #expect(!ColumnMetadataRules.sqliteIsPrimaryKey(pk: nil))
    }

    @Test("SQLite treats a lone INTEGER primary key as the rowid alias")
    func sqliteRowIdAlias() {
        #expect(ColumnMetadataRules.sqliteIsRowIdAlias(
            typeName: "INTEGER", isPrimaryKey: true, primaryKeyCount: 1,
            createStatement: "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"
        ))
        #expect(!ColumnMetadataRules.sqliteIsRowIdAlias(
            typeName: "TEXT", isPrimaryKey: true, primaryKeyCount: 1,
            createStatement: "CREATE TABLE t (id TEXT PRIMARY KEY)"
        ))
    }

    @Test("SQLite never treats a composite primary key as the rowid alias")
    func sqliteCompositeKeyIsNotRowId() {
        #expect(!ColumnMetadataRules.sqliteIsRowIdAlias(
            typeName: "INTEGER", isPrimaryKey: true, primaryKeyCount: 2,
            createStatement: "CREATE TABLE t (a INTEGER, b INTEGER, PRIMARY KEY (a, b))"
        ))
    }

    @Test("a WITHOUT ROWID primary key is an ordinary column the database will not fill in")
    func sqliteWithoutRowIdIsNotAnAlias() {
        #expect(!ColumnMetadataRules.sqliteIsRowIdAlias(
            typeName: "INTEGER", isPrimaryKey: true, primaryKeyCount: 1,
            createStatement: "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT) WITHOUT ROWID"
        ))
    }
}
