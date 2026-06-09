//
//  MariaDBFieldClassifierTests.swift
//  TableProTests
//

#if canImport(MySQLDriverPlugin)
import Foundation
import TableProPluginKit
import Testing

@testable import MySQLDriverPlugin

@Suite("MariaDBFieldClassifier")
struct MariaDBFieldClassifierTests {
    @Test("makeColumnMeta reads PRIMARY KEY, NOT NULL, and AUTO_INCREMENT flags")
    func makeColumnMetaReadsKeyFlags() {
        let pk = makeColumnMeta(
            name: "id", typeName: "int",
            flags: mysqlPriKeyFlag | mysqlNotNullFlag | mysqlAutoIncrementFlag
        )
        #expect(pk.isPrimaryKey)
        #expect(!pk.isNullable)
        #expect(pk.isIdentity)

        let plain = makeColumnMeta(name: "name", typeName: "varchar", flags: 0)
        #expect(!plain.isPrimaryKey)
        #expect(plain.isNullable)
        #expect(!plain.isIdentity)
    }

    @Test("BIT no longer routes to binary (it was rendering as raw control characters in the data grid)")
    func bitIsNotBinary() {
        #expect(!MariaDBFieldClassifier.isBinary(typeRaw: 16, charset: 63))
        #expect(!MariaDBFieldClassifier.isBinary(typeRaw: 16, charset: 33))
    }

    @Test("isBit identifies type code 16 and only type code 16")
    func isBitMatchesOnlyBitType() {
        #expect(MariaDBFieldClassifier.isBit(typeRaw: 16))
        for typeRaw: UInt32 in [0, 1, 2, 3, 7, 12, 15, 17, 245, 252, 255] {
            #expect(!MariaDBFieldClassifier.isBit(typeRaw: typeRaw))
        }
    }

    @Test("bitFieldToString decodes a single byte big-endian")
    func bitFieldSingleByte() {
        #expect(decodeBitField([0x00]) == "0")
        #expect(decodeBitField([0x01]) == "1")
        #expect(decodeBitField([0x7f]) == "127")
        #expect(decodeBitField([0xff]) == "255")
    }

    @Test("bitFieldToString decodes multi-byte values MSB-first")
    func bitFieldMultiByte() {
        #expect(decodeBitField([0x01, 0x00]) == "256")
        #expect(decodeBitField([0xff, 0xff]) == "65535")
        #expect(decodeBitField([0x12, 0x34]) == "4660")
    }

    @Test("bitFieldToString handles BIT(64) up to UInt64.max")
    func bitField64Bits() {
        let allOnes: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        #expect(decodeBitField(allOnes) == "18446744073709551615")
        let halfPlusOne: [UInt8] = [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        #expect(decodeBitField(halfPlusOne) == "9223372036854775808")
    }

    @Test("bitFieldToString on an empty buffer returns 0")
    func bitFieldEmptyBuffer() {
        #expect(decodeBitField([]) == "0")
    }

    @Test("Data overload matches the raw-pointer overload")
    func bitFieldDataOverload() {
        let bytes: [UInt8] = [0x01, 0xff]
        let dataResult = MariaDBFieldClassifier.bitFieldToString(Data(bytes))
        #expect(dataResult == "511")
        #expect(dataResult == decodeBitField(bytes))
    }

    private func decodeBitField(_ bytes: [UInt8]) -> String {
        bytes.withUnsafeBytes { MariaDBFieldClassifier.bitFieldToString($0) }
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
