//
//  MySQLStorageWidthTests.swift
//  TableProTests
//
//  Every boundary here was measured on MariaDB 12.3.3 (utf8mb4, ROW_FORMAT=DYNAMIC, 16 KB pages,
//  innodb_strict_mode on): the side that fits was created and the side that does not was refused.
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
        XCTAssertNil(Width.exceededLimit(of: [column(varchar(16_383))], hasPrimaryKey: false))

        let over = [column(varchar(16_383)), column(.integer(bytes: 1), nullable: false)]
        XCTAssertEqual(Width.rowBytes(of: over), 65_536)
        XCTAssertEqual(Width.exceededLimit(of: over, hasPrimaryKey: false), .row)
    }

    /// A `CHAR` in utf8mb4 has no length prefix in the row but is variable length in InnoDB.
    func testAFixedLengthTextCountsDifferentlyInTheRowAndTheRecord() {
        XCTAssertEqual(Width.rowBytes(.text(length: 50, isFixed: true)), 200)
        XCTAssertEqual(Width.recordBytes(.text(length: 50, isFixed: true)), 201)
        XCTAssertEqual(Width.rowBytes(varchar(50)), 201)
    }

    /// A column over 255 bytes, and any `TEXT`, can leave the page, so the record counts 41 for it.
    func testALongColumnCountsOnlyWhatStaysInTheRecord() {
        XCTAssertEqual(Width.recordBytes(varchar(63)), 253)
        XCTAssertEqual(Width.recordBytes(varchar(64)), 41)
        XCTAssertEqual(Width.recordBytes(.text(length: nil, isFixed: false)), 41)
        XCTAssertEqual(Width.rowBytes(varchar(1_000)), 4_002)
        XCTAssertEqual(Width.rowBytes(.text(length: nil, isFixed: false)), 12)
    }

    /// A `BIGINT` primary key, 31 nullable `VARCHAR(63)` and 252 `TINYINT NOT NULL` columns were
    /// created at 8,125 bytes; one more `TINYINT` was refused with ERROR 1118.
    func testTheRecordLimitIsHalfAPage() {
        let key = column(.integer(bytes: 8), nullable: false)
        let texts = Array(repeating: column(varchar(63)), count: 31)
        let bytes = Array(repeating: column(.integer(bytes: 1), nullable: false), count: 252)
        let fits = [key] + texts + bytes
        XCTAssertEqual(Width.recordBytes(of: fits, hasPrimaryKey: true), 8_125)
        XCTAssertNil(Width.exceededLimit(of: fits, hasPrimaryKey: true))

        let over = fits + [column(.integer(bytes: 1), nullable: false)]
        XCTAssertEqual(Width.recordBytes(of: over, hasPrimaryKey: true), 8_126)
        XCTAssertEqual(Width.exceededLimit(of: over, hasPrimaryKey: true), .record)
    }

    /// Without a primary key InnoDB adds a six-byte row id.
    func testATableWithoutAPrimaryKeyCountsTheRowId() {
        let columns = [column(.integer(bytes: 4))]
        XCTAssertEqual(
            Width.recordBytes(of: columns, hasPrimaryKey: false) - Width.recordBytes(of: columns, hasPrimaryKey: true),
            6
        )
    }
}
