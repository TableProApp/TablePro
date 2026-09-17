//
//  MySQLStorageWidthTests.swift
//  TableProTests
//
//  Every boundary here was measured on MySQL 8.4.11 and MariaDB 12.3.3 (utf8mb4, ROW_FORMAT=DYNAMIC,
//  16 KB pages, innodb_strict_mode on): the side that fits was created and the side that does not
//  was refused.
//

@testable import TablePro
import XCTest

final class MySQLStorageWidthTests: XCTestCase {
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
    func testATextKeyPartCountsFourBytesACharacter() {
        let bigint = Width.keyBytes(.integer(bytes: 8)) ?? 0
        XCTAssertEqual((Width.keyBytes(varchar(766)) ?? 0) + bigint, 3_072)
        XCTAssertEqual((Width.keyBytes(varchar(767)) ?? 0) + bigint, 3_076)
    }

    func testFixedKeyPartsCountTheirStorage() {
        XCTAssertEqual(Width.keyBytes(.timestamp(precision: 6, hasTimeZone: false)), 8)
        XCTAssertEqual(Width.keyBytes(.decimal(precision: 65, scale: 30)), 30)
        XCTAssertEqual(Width.keyBytes(.date), 3)
        XCTAssertEqual(Width.keyBytes(.integer(bytes: 4)), 4)
        XCTAssertEqual(Width.keyBytes(.binary(length: 3_064, isFixed: false)), 3_064)
    }

    func testAnUnboundedKeyPartHasAWidthOnlyWithAPrefix() {
        XCTAssertNil(Width.keyBytes(.text(length: nil, isFixed: false)))
        XCTAssertNil(Width.keyBytes(.json))
        XCTAssertEqual(Width.keyBytes(.text(length: nil, isFixed: false), prefix: 255), 1_020)
        XCTAssertEqual(Width.keyBytes(.binary(length: nil, isFixed: false), prefix: 255), 255)
        XCTAssertEqual(Width.keyBytes(varchar(1_000), prefix: 255), 1_020)
    }

    func testDecimalsPackNineDigitsToFourBytes() {
        XCTAssertEqual(Width.decimalBytes(precision: 65, scale: 30), 30)
        XCTAssertEqual(Width.decimalBytes(precision: 10, scale: 2), 5)
        XCTAssertEqual(Width.decimalBytes(precision: 19, scale: 4), 9)
    }

    // MARK: - Rows

    /// One `VARCHAR(16383) NULL` was created at 65,535 bytes, and with a `TINYINT NOT NULL` beside it
    /// was refused at 65,536.
    func testTheRowLimitCountsLengthPrefixesAndTheNullBitmap() {
        XCTAssertEqual(Width.rowBytes(of: [column(varchar(16_383), nullable: false)]), 65_534)
        XCTAssertEqual(Width.rowBytes(of: [column(varchar(16_383))]), 65_535)
        XCTAssertNil(Width.exceededLimit(of: [column(varchar(16_383))], hasPrimaryKey: false, flavor: .mysql))

        let over = [column(varchar(16_383)), column(.integer(bytes: 1), nullable: false)]
        XCTAssertEqual(Width.rowBytes(of: over), 65_536)
        XCTAssertEqual(Width.exceededLimit(of: over, hasPrimaryKey: false, flavor: .mysql), .row)
        XCTAssertEqual(Width.exceededLimit(of: over, hasPrimaryKey: false, flavor: .mariadb), .row)
    }

    /// Both servers count the row the same way: `VARCHAR(63)` 253, `VARCHAR(64)` 258, `CHAR(50)` 200
    /// and `LONGTEXT` 12.
    func testBothServersCountTheRowAlike() {
        XCTAssertEqual(Width.rowBytes(varchar(63)), 253)
        XCTAssertEqual(Width.rowBytes(varchar(64)), 258)
        XCTAssertEqual(Width.rowBytes(.text(length: 50, isFixed: true)), 200)
        XCTAssertEqual(Width.rowBytes(varchar(1_000)), 4_002)
        XCTAssertEqual(Width.rowBytes(.text(length: nil, isFixed: false)), 12)
    }

    // MARK: - Records

    /// MySQL counts a variable column, a utf8mb4 `CHAR` and a `TEXT` alike once it passes 40 bytes.
    func testMySQLCountsAVariableColumnPast40BytesAs41() {
        XCTAssertEqual(Width.recordBytes(varchar(5), flavor: .mysql), 21)
        XCTAssertEqual(Width.recordBytes(varchar(10), flavor: .mysql), 41)
        XCTAssertEqual(Width.recordBytes(varchar(11), flavor: .mysql), 41)
        XCTAssertEqual(Width.recordBytes(varchar(1_000), flavor: .mysql), 41)
        XCTAssertEqual(Width.recordBytes(.text(length: 50, isFixed: true), flavor: .mysql), 41)
        XCTAssertEqual(Width.recordBytes(.binary(length: 255, isFixed: false), flavor: .mysql), 41)
        XCTAssertEqual(Width.recordBytes(.text(length: nil, isFixed: false), flavor: .mysql), 41)
        XCTAssertEqual(Width.recordBytes(.binary(length: 100, isFixed: true), flavor: .mysql), 100)
    }

    /// MariaDB counts a variable column of up to 255 bytes whole, and a longer one and every `TEXT`
    /// as 21.
    func testMariaDBCountsAColumnOfUpTo255BytesWhole() {
        XCTAssertEqual(Width.recordBytes(varchar(11), flavor: .mariadb), 45)
        XCTAssertEqual(Width.recordBytes(varchar(63), flavor: .mariadb), 253)
        XCTAssertEqual(Width.recordBytes(varchar(64), flavor: .mariadb), 21)
        XCTAssertEqual(Width.recordBytes(.text(length: 50, isFixed: true), flavor: .mariadb), 201)
        XCTAssertEqual(Width.recordBytes(.binary(length: 255, isFixed: false), flavor: .mariadb), 256)
        XCTAssertEqual(Width.recordBytes(.binary(length: 256, isFixed: false), flavor: .mariadb), 21)
        XCTAssertEqual(Width.recordBytes(.text(length: nil, isFixed: false), flavor: .mariadb), 21)
        XCTAssertEqual(Width.recordBytes(.binary(length: 100, isFixed: true), flavor: .mariadb), 100)
    }

    /// An `INT` primary key, ten `VARCHAR(50) NOT NULL` and 7,693 bytes of `BINARY NOT NULL` were
    /// created on MySQL at 8,125 bytes, and one more byte was refused with ERROR 1118. MariaDB
    /// refused the same table.
    func testTheRecordLimitIsHalfAPage() {
        let key = column(.integer(bytes: 4), nullable: false)
        let texts = Array(repeating: column(varchar(50), nullable: false), count: 10)
        let filler = Array(repeating: column(.binary(length: 255, isFixed: true), nullable: false), count: 30)
            + [column(.binary(length: 43, isFixed: true), nullable: false)]
        let fits = [key] + texts + filler
        XCTAssertEqual(Width.recordBytes(of: fits, hasPrimaryKey: true, flavor: .mysql), 8_125)
        XCTAssertNil(Width.exceededLimit(of: fits, hasPrimaryKey: true, flavor: .mysql))
        XCTAssertEqual(Width.exceededLimit(of: fits, hasPrimaryKey: true, flavor: .mariadb), .record)

        let over = fits + [column(.binary(length: 1, isFixed: true), nullable: false)]
        XCTAssertEqual(Width.recordBytes(of: over, hasPrimaryKey: true, flavor: .mysql), 8_126)
        XCTAssertEqual(Width.exceededLimit(of: over, hasPrimaryKey: true, flavor: .mysql), .record)
    }

    /// A `BIGINT` primary key and 41 nullable `VARCHAR(50)` columns were created on MySQL and refused
    /// by MariaDB; 40 were created on both.
    func testTheSameTableFitsOneServerAndNotTheOther() {
        let key = column(.integer(bytes: 8), nullable: false)
        let fortyOne = [key] + Array(repeating: column(varchar(50)), count: 41)
        XCTAssertNil(Width.exceededLimit(of: fortyOne, hasPrimaryKey: true, flavor: .mysql))
        XCTAssertEqual(Width.exceededLimit(of: fortyOne, hasPrimaryKey: true, flavor: .mariadb), .record)

        let forty = [key] + Array(repeating: column(varchar(50)), count: 40)
        XCTAssertNil(Width.exceededLimit(of: forty, hasPrimaryKey: true, flavor: .mariadb))
    }

    /// Without a primary key InnoDB adds a six-byte row id.
    func testATableWithoutAPrimaryKeyCountsTheRowId() {
        let columns = [column(.integer(bytes: 4))]
        XCTAssertEqual(
            Width.recordBytes(of: columns, hasPrimaryKey: false, flavor: .mysql)
                - Width.recordBytes(of: columns, hasPrimaryKey: true, flavor: .mysql),
            6
        )
    }

    // MARK: - Flavor

    /// A MariaDB server is often reached through a connection typed MySQL, so the banner decides.
    func testTheServersBannerDecidesTheFlavor() {
        XCTAssertEqual(Width.Flavor.of(.mysql, serverVersion: "8.4.11"), .mysql)
        XCTAssertEqual(Width.Flavor.of(.mysql, serverVersion: "12.3.3-MariaDB"), .mariadb)
        XCTAssertEqual(Width.Flavor.of(.mariadb, serverVersion: "5.5.5-10.11.6-MariaDB-log"), .mariadb)
        XCTAssertEqual(Width.Flavor.of(DatabaseType(rawValue: "TiDB"), serverVersion: "8.0.11-TiDB-v7.5.0"), .mysql)
        XCTAssertEqual(Width.Flavor.of(.mariadb, serverVersion: nil), .mariadb)
        XCTAssertEqual(Width.Flavor.of(.mysql, serverVersion: nil), .mysql)
    }
}
