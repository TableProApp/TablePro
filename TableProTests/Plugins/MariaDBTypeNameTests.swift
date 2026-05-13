//
//  MariaDBTypeNameTests.swift
//  TableProTests
//

#if canImport(MySQLDriverPlugin)
import Testing

@testable import MySQLDriverPlugin

@Suite("MariaDB type name resolution")
struct MariaDBTypeNameTests {
    private func resolve(typeRaw: UInt32, charsetnr: UInt32 = 33, flags: UInt = 0, length: UInt = 0) -> String {
        mariaDBTypeName(typeRaw: typeRaw, flags: flags, charsetnr: charsetnr, length: length)
    }

    private let binaryFlagAndCharset: (flags: UInt, charsetnr: UInt32) = (mysqlBinaryFlag, mysqlBinaryCharset)

    // MARK: - Numeric types (regression for #1209: numeric routed as bytes)

    @Test("INT family resolves to numeric type names")
    func numericTypes() {
        #expect(resolve(typeRaw: 1) == "TINYINT")
        #expect(resolve(typeRaw: 2) == "SMALLINT")
        #expect(resolve(typeRaw: 3) == "INT")
        #expect(resolve(typeRaw: 8) == "BIGINT")
        #expect(resolve(typeRaw: 9) == "MEDIUMINT")
    }

    @Test("DECIMAL and floating point resolve to their type names")
    func decimalAndFloat() {
        #expect(resolve(typeRaw: 0) == "DECIMAL")
        #expect(resolve(typeRaw: 4) == "FLOAT")
        #expect(resolve(typeRaw: 5) == "DOUBLE")
        #expect(resolve(typeRaw: 246) == "NEWDECIMAL")
    }

    // MARK: - Temporal types

    @Test("Temporal types resolve to their type names")
    func temporalTypes() {
        #expect(resolve(typeRaw: 7) == "TIMESTAMP")
        #expect(resolve(typeRaw: 10) == "DATE")
        #expect(resolve(typeRaw: 11) == "TIME")
        #expect(resolve(typeRaw: 12) == "DATETIME")
        #expect(resolve(typeRaw: 13) == "YEAR")
        #expect(resolve(typeRaw: 14) == "NEWDATE")
    }

    // MARK: - Misc

    @Test("JSON, BIT, GEOMETRY resolve to their type names")
    func miscTypes() {
        #expect(resolve(typeRaw: 16) == "BIT")
        #expect(resolve(typeRaw: 245) == "JSON")
        #expect(resolve(typeRaw: 255) == "GEOMETRY")
    }

    @Test("Unknown type code returns UNKNOWN")
    func unknownType() {
        #expect(resolve(typeRaw: 999) == "UNKNOWN")
    }

    // MARK: - BINARY / VARBINARY (regression for #1217: data wipe on edit)

    @Test("BINARY(N) resolves to BINARY only when binary flag set")
    func binaryWithFlagAndCharset() {
        let (flags, charsetnr) = binaryFlagAndCharset
        #expect(resolve(typeRaw: 254, charsetnr: charsetnr, flags: flags) == "BINARY")
    }

    @Test("CHAR(N) without binary flag stays CHAR")
    func charWithoutBinaryFlag() {
        #expect(resolve(typeRaw: 254, charsetnr: 33, flags: 0) == "CHAR")
    }

    @Test("CHAR with charset 63 but no binary flag stays CHAR")
    func charBinaryCharsetWithoutFlag() {
        #expect(resolve(typeRaw: 254, charsetnr: mysqlBinaryCharset, flags: 0) == "CHAR")
    }

    @Test("CHAR with binary flag but non-binary charset stays CHAR")
    func charFlagWithoutBinaryCharset() {
        #expect(resolve(typeRaw: 254, charsetnr: 33, flags: mysqlBinaryFlag) == "CHAR")
    }

    @Test("VARBINARY(N) resolves to VARBINARY only when binary flag set with charset 63")
    func varbinaryWithFlagAndCharset() {
        let (flags, charsetnr) = binaryFlagAndCharset
        #expect(resolve(typeRaw: 253, charsetnr: charsetnr, flags: flags) == "VARBINARY")
    }

    @Test("VARCHAR(N) without binary flag stays VARCHAR")
    func varcharWithoutBinaryFlag() {
        #expect(resolve(typeRaw: 253, charsetnr: 33, flags: 0) == "VARCHAR")
    }

    // MARK: - BLOB family

    @Test("BLOB family resolves binary vs text by isBinary flag")
    func blobFamilyBinaryVsText() {
        let (flags, charsetnr) = binaryFlagAndCharset
        #expect(resolve(typeRaw: 249, charsetnr: charsetnr, flags: flags) == "TINYBLOB")
        #expect(resolve(typeRaw: 249, charsetnr: 33, flags: 0) == "TINYTEXT")
        #expect(resolve(typeRaw: 250, charsetnr: charsetnr, flags: flags) == "MEDIUMBLOB")
        #expect(resolve(typeRaw: 250, charsetnr: 33, flags: 0) == "MEDIUMTEXT")
        #expect(resolve(typeRaw: 251, charsetnr: charsetnr, flags: flags) == "LONGBLOB")
        #expect(resolve(typeRaw: 251, charsetnr: 33, flags: 0) == "LONGTEXT")
    }

    @Test("Generic BLOB (252) routes by length and binary flag")
    func blobLengthRouting() {
        let (flags, charsetnr) = binaryFlagAndCharset
        #expect(resolve(typeRaw: 252, charsetnr: charsetnr, flags: flags, length: 100) == "BLOB")
        #expect(resolve(typeRaw: 252, charsetnr: charsetnr, flags: flags, length: 100_000) == "LONGBLOB")
        #expect(resolve(typeRaw: 252, charsetnr: 33, flags: 0, length: 100) == "TEXT")
        #expect(resolve(typeRaw: 252, charsetnr: 33, flags: 0, length: 100_000) == "LONGTEXT")
    }
}
#endif
