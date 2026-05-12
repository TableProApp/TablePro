//
//  MariaDBFieldClassifierTests.swift
//  TableProTests
//

#if canImport(MySQLDriverPlugin)
import Testing

@testable import MySQLDriverPlugin

@Suite("MariaDBFieldClassifier")
struct MariaDBFieldClassifierTests {
    @Test("BIT routes to binary regardless of charset")
    func bitIsBinary() {
        #expect(MariaDBFieldClassifier.isBinary(typeRaw: 16, charset: 63))
        #expect(MariaDBFieldClassifier.isBinary(typeRaw: 16, charset: 33))
    }

    @Test("BLOB family with binary charset routes to binary")
    func blobFamilyBinary() {
        for typeRaw: UInt32 in [249, 250, 251, 252] {
            #expect(MariaDBFieldClassifier.isBinary(typeRaw: typeRaw, charset: 63))
        }
    }

    @Test("VAR_STRING and STRING route to binary only with charset 63")
    func varStringBinaryOnlyWithBinaryCharset() {
        #expect(MariaDBFieldClassifier.isBinary(typeRaw: 253, charset: 63))
        #expect(MariaDBFieldClassifier.isBinary(typeRaw: 254, charset: 63))
        #expect(!MariaDBFieldClassifier.isBinary(typeRaw: 253, charset: 33))
        #expect(!MariaDBFieldClassifier.isBinary(typeRaw: 254, charset: 255))
    }

    @Test("TEXT family with non-binary charset routes to text")
    func textFamilyIsText() {
        for typeRaw: UInt32 in [249, 250, 251, 252] {
            #expect(!MariaDBFieldClassifier.isBinary(typeRaw: typeRaw, charset: 33))
        }
    }

    @Test("Numeric types never route to binary even with binary charset")
    func numericTypesNeverBinary() {
        let numericTypes: [UInt32] = [
            0,   // DECIMAL
            1,   // TINY
            2,   // SHORT
            3,   // LONG (INT)
            4,   // FLOAT
            5,   // DOUBLE
            8,   // LONGLONG (BIGINT)
            9,   // INT24 (MEDIUMINT)
            246  // NEWDECIMAL
        ]
        for typeRaw in numericTypes {
            #expect(!MariaDBFieldClassifier.isBinary(typeRaw: typeRaw, charset: 63))
            #expect(!MariaDBFieldClassifier.isBinary(typeRaw: typeRaw, charset: 33))
        }
    }

    @Test("Temporal types never route to binary")
    func temporalTypesNeverBinary() {
        let temporalTypes: [UInt32] = [
            7,   // TIMESTAMP
            10,  // DATE
            11,  // TIME
            12,  // DATETIME
            13,  // YEAR
            14   // NEWDATE
        ]
        for typeRaw in temporalTypes {
            #expect(!MariaDBFieldClassifier.isBinary(typeRaw: typeRaw, charset: 63))
        }
    }

    @Test("JSON, ENUM, SET, GEOMETRY route to text")
    func miscTextTypes() {
        #expect(!MariaDBFieldClassifier.isBinary(typeRaw: 245, charset: 63)) // JSON
        #expect(!MariaDBFieldClassifier.isBinary(typeRaw: 247, charset: 33)) // ENUM
        #expect(!MariaDBFieldClassifier.isBinary(typeRaw: 248, charset: 33)) // SET
        #expect(!MariaDBFieldClassifier.isBinary(typeRaw: 255, charset: 63)) // GEOMETRY (handled upstream)
    }
}
#endif
