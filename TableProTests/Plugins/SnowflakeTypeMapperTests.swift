//
//  SnowflakeTypeMapperTests.swift
//  TableProTests
//
//  Tests for SnowflakeTypeMapper (compiled via symlink from SnowflakeDriverPlugin).
//

import Foundation
import Testing

@Suite("Snowflake Type Mapper")
struct SnowflakeTypeMapperTests {
    private func column(
        _ type: String,
        precision: Int? = nil,
        scale: Int? = nil,
        length: Int? = nil
    ) -> SnowflakeColumnMeta {
        SnowflakeColumnMeta(
            name: "c",
            internalType: type,
            nullable: true,
            precision: precision,
            scale: scale,
            length: length
        )
    }

    @Test("Fixed with scale renders precision and scale")
    func testFixedWithScale() {
        #expect(SnowflakeTypeMapper.displayType(for: column("fixed", precision: 10, scale: 2)) == "NUMBER(10,2)")
        #expect(SnowflakeTypeMapper.displayType(for: column("fixed", scale: 3)) == "NUMBER(38,3)")
    }

    @Test("Fixed without scale renders plain NUMBER")
    func testFixedWithoutScale() {
        #expect(SnowflakeTypeMapper.displayType(for: column("fixed", precision: 38, scale: 0)) == "NUMBER")
        #expect(SnowflakeTypeMapper.displayType(for: column("FIXED")) == "NUMBER")
    }

    @Test("Text renders VARCHAR with optional length")
    func testText() {
        #expect(SnowflakeTypeMapper.displayType(for: column("text", length: 255)) == "VARCHAR(255)")
        #expect(SnowflakeTypeMapper.displayType(for: column("text")) == "VARCHAR")
    }

    @Test("Real maps to FLOAT and timestamps keep their zone variant")
    func testRealAndTimestamps() {
        #expect(SnowflakeTypeMapper.displayType(for: column("real")) == "FLOAT")
        #expect(SnowflakeTypeMapper.displayType(for: column("timestamp_ntz")) == "TIMESTAMP_NTZ")
        #expect(SnowflakeTypeMapper.displayType(for: column("timestamp_ltz")) == "TIMESTAMP_LTZ")
        #expect(SnowflakeTypeMapper.displayType(for: column("timestamp_tz")) == "TIMESTAMP_TZ")
    }

    @Test("Unknown internal types fall back to their uppercased name")
    func testUnknownType() {
        #expect(SnowflakeTypeMapper.displayType(for: column("vector")) == "VECTOR")
    }
}
