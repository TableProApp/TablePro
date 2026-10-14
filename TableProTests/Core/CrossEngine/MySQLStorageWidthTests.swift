//
//  MySQLStorageWidthTests.swift
//  TableProTests
//
//  Every boundary here was measured on MySQL 8.4.11 and MariaDB 12.3.3 (utf8mb4, ROW_FORMAT=DYNAMIC,
//  16 KB pages, innodb_strict_mode on): the side that fits was created and the side that does not
//  was refused.
//

import Foundation
@testable import TablePro
import Testing

struct MySQLStorageWidthTests {
    private typealias Width = MySQLStorageWidth

    private func varchar(_ length: Int) -> CanonicalTypeKind {
        .text(length: length, isFixed: false)
    }

    private func column(_ kind: CanonicalTypeKind, nullable: Bool = true) -> Width.Column {
        Width.Column(kind: kind, isNullable: nullable)
    }

    // MARK: - Keys

    /// `PRIMARY KEY (VARCHAR(766), BIGINT)` was created and `(VARCHAR(767), BIGINT)` refused with
    /// ERROR 1071.
    @Test
    func aTextKeyPartCountsFourBytesACharacter() {
        let bigint = Width.keyBytes(.integer(bytes: 8)) ?? 0
        #expect((Width.keyBytes(varchar(766)) ?? 0) + bigint == 3_072)
        #expect((Width.keyBytes(varchar(767)) ?? 0) + bigint == 3_076)
    }

    @Test
    func fixedKeyPartsCountTheirStorage() {
        #expect(Width.keyBytes(.timestamp(precision: 6, hasTimeZone: false)) == 8)
        #expect(Width.keyBytes(.decimal(precision: 65, scale: 30)) == 30)
        #expect(Width.keyBytes(.date) == 3)
        #expect(Width.keyBytes(.integer(bytes: 4)) == 4)
        #expect(Width.keyBytes(.binary(length: 3_064, isFixed: false)) == 3_064)
    }

    @Test
    func anUnboundedKeyPartHasAWidthOnlyWithAPrefix() {
        #expect(Width.keyBytes(.text(length: nil, isFixed: false)) == nil)
        #expect(Width.keyBytes(.json) == nil)
        #expect(Width.keyBytes(.text(length: nil, isFixed: false), prefix: 255) == 1_020)
        #expect(Width.keyBytes(.binary(length: nil, isFixed: false), prefix: 255) == 255)
        #expect(Width.keyBytes(varchar(1_000), prefix: 255) == 1_020)
    }

    @Test
    func decimalsPackNineDigitsToFourBytes() {
        #expect(Width.decimalBytes(precision: 65, scale: 30) == 30)
        #expect(Width.decimalBytes(precision: 10, scale: 2) == 5)
        #expect(Width.decimalBytes(precision: 19, scale: 4) == 9)
    }

    // MARK: - Rows

    /// One `VARCHAR(16383) NULL` was created at 65,535 bytes, and with a `TINYINT NOT NULL` beside it
    /// was refused at 65,536.
    @Test
    func theRowLimitCountsLengthPrefixesAndTheNullBitmap() {
        #expect(Width.rowBytes(of: [column(varchar(16_383), nullable: false)]) == 65_534)
        #expect(Width.rowBytes(of: [column(varchar(16_383))]) == 65_535)
        #expect(Width.exceededLimit(of: [column(varchar(16_383))], hasPrimaryKey: false, flavor: .mysql) == nil)

        let over = [column(varchar(16_383)), column(.integer(bytes: 1), nullable: false)]
        #expect(Width.rowBytes(of: over) == 65_536)
        #expect(Width.exceededLimit(of: over, hasPrimaryKey: false, flavor: .mysql) == .row)
        #expect(Width.exceededLimit(of: over, hasPrimaryKey: false, flavor: .mariadb) == .row)
    }

    /// Both servers count the row the same way: `VARCHAR(63)` 253, `VARCHAR(64)` 258, `CHAR(50)` 200
    /// and `LONGTEXT` 12.
    @Test
    func bothServersCountTheRowAlike() {
        #expect(Width.rowBytes(varchar(63)) == 253)
        #expect(Width.rowBytes(varchar(64)) == 258)
        #expect(Width.rowBytes(.text(length: 50, isFixed: true)) == 200)
        #expect(Width.rowBytes(varchar(1_000)) == 4_002)
        #expect(Width.rowBytes(.text(length: nil, isFixed: false)) == 12)
    }

    // MARK: - Records

    /// MySQL counts a variable column, a utf8mb4 `CHAR` and a `TEXT` alike once it passes 40 bytes.
    @Test
    func mySQLCountsAVariableColumnPast40BytesAs41() {
        #expect(Width.recordBytes(varchar(5), flavor: .mysql) == 21)
        #expect(Width.recordBytes(varchar(10), flavor: .mysql) == 41)
        #expect(Width.recordBytes(varchar(11), flavor: .mysql) == 41)
        #expect(Width.recordBytes(varchar(1_000), flavor: .mysql) == 41)
        #expect(Width.recordBytes(.text(length: 50, isFixed: true), flavor: .mysql) == 41)
        #expect(Width.recordBytes(.binary(length: 255, isFixed: false), flavor: .mysql) == 41)
        #expect(Width.recordBytes(.text(length: nil, isFixed: false), flavor: .mysql) == 41)
        #expect(Width.recordBytes(.binary(length: 100, isFixed: true), flavor: .mysql) == 100)
    }

    /// MariaDB counts a variable column of up to 255 bytes whole, and a longer one and every `TEXT`
    /// as 21.
    @Test
    func mariaDBCountsAColumnOfUpTo255BytesWhole() {
        #expect(Width.recordBytes(varchar(11), flavor: .mariadb) == 45)
        #expect(Width.recordBytes(varchar(63), flavor: .mariadb) == 253)
        #expect(Width.recordBytes(varchar(64), flavor: .mariadb) == 21)
        #expect(Width.recordBytes(.text(length: 50, isFixed: true), flavor: .mariadb) == 201)
        #expect(Width.recordBytes(.binary(length: 255, isFixed: false), flavor: .mariadb) == 256)
        #expect(Width.recordBytes(.binary(length: 256, isFixed: false), flavor: .mariadb) == 21)
        #expect(Width.recordBytes(.text(length: nil, isFixed: false), flavor: .mariadb) == 21)
        #expect(Width.recordBytes(.binary(length: 100, isFixed: true), flavor: .mariadb) == 100)
    }

    /// An `INT` primary key, ten `VARCHAR(50) NOT NULL` and 7,693 bytes of `BINARY NOT NULL` were
    /// created on MySQL at 8,125 bytes, and one more byte was refused with ERROR 1118. MariaDB
    /// refused the same table.
    @Test
    func theRecordLimitIsHalfAPage() {
        let key = column(.integer(bytes: 4), nullable: false)
        let texts = Array(repeating: column(varchar(50), nullable: false), count: 10)
        let filler = Array(repeating: column(.binary(length: 255, isFixed: true), nullable: false), count: 30)
            + [column(.binary(length: 43, isFixed: true), nullable: false)]
        let fits = [key] + texts + filler
        #expect(Width.recordBytes(of: fits, hasPrimaryKey: true, flavor: .mysql) == 8_125)
        #expect(Width.exceededLimit(of: fits, hasPrimaryKey: true, flavor: .mysql) == nil)
        #expect(Width.exceededLimit(of: fits, hasPrimaryKey: true, flavor: .mariadb) == .record)

        let over = fits + [column(.binary(length: 1, isFixed: true), nullable: false)]
        #expect(Width.recordBytes(of: over, hasPrimaryKey: true, flavor: .mysql) == 8_126)
        #expect(Width.exceededLimit(of: over, hasPrimaryKey: true, flavor: .mysql) == .record)
    }

    /// A `BIGINT` primary key and 41 nullable `VARCHAR(50)` columns were created on MySQL and refused
    /// by MariaDB; 40 were created on both.
    @Test
    func theSameTableFitsOneServerAndNotTheOther() {
        let key = column(.integer(bytes: 8), nullable: false)
        let fortyOne = [key] + Array(repeating: column(varchar(50)), count: 41)
        #expect(Width.exceededLimit(of: fortyOne, hasPrimaryKey: true, flavor: .mysql) == nil)
        #expect(Width.exceededLimit(of: fortyOne, hasPrimaryKey: true, flavor: .mariadb) == .record)

        let forty = [key] + Array(repeating: column(varchar(50)), count: 40)
        #expect(Width.exceededLimit(of: forty, hasPrimaryKey: true, flavor: .mariadb) == nil)
    }

    /// Without a primary key InnoDB adds a six-byte row id.
    @Test
    func aTableWithoutAPrimaryKeyCountsTheRowId() {
        let columns = [column(.integer(bytes: 4))]
        #expect(Width.recordBytes(of: columns, hasPrimaryKey: false, flavor: .mysql)
                - Width.recordBytes(of: columns, hasPrimaryKey: true, flavor: .mysql) == 6)
    }

    // MARK: - Flavor

    /// A MariaDB server is often reached through a connection typed MySQL, so the banner decides.
    @Test
    func theServersBannerDecidesTheFlavor() {
        #expect(Width.Flavor.of(.mysql, serverVersion: "8.4.11") == .mysql)
        #expect(Width.Flavor.of(.mysql, serverVersion: "12.3.3-MariaDB") == .mariadb)
        #expect(Width.Flavor.of(.mariadb, serverVersion: "5.5.5-10.11.6-MariaDB-log") == .mariadb)
        #expect(Width.Flavor.of(DatabaseType(rawValue: "TiDB"), serverVersion: "8.0.11-TiDB-v7.5.0") == .mysql)
        #expect(Width.Flavor.of(.mariadb, serverVersion: nil) == .mariadb)
        #expect(Width.Flavor.of(.mysql, serverVersion: nil) == .mysql)
    }
}
