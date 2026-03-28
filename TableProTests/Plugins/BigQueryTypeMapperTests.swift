//
//  BigQueryTypeMapperTests.swift
//  TableProTests
//
//  Tests for BigQueryTypeMapper (compiled via symlink from BigQueryDriverPlugin).
//

import Foundation
import TableProPluginKit
import Testing

private func field(_ name: String, _ type: String, mode: String? = nil, description: String? = nil,
                   fields: [BQTableFieldSchema]? = nil) -> BQTableFieldSchema {
    BQTableFieldSchema(name: name, type: type, mode: mode, description: description, fields: fields)
}

private func response(rows: [BQQueryResponse.BQRow]?, totalRows: String = "0") -> BQQueryResponse {
    BQQueryResponse(schema: nil, rows: rows, totalRows: totalRows, pageToken: nil, jobComplete: true, jobReference: nil, numDmlAffectedRows: nil)
}

@Suite("BigQueryTypeMapper - Column Type Names")
struct BigQueryTypeMapperColumnTypeTests {
    @Test("Simple types return type string as-is")
    func simpleTypes() {
        let schema = BQTableSchema(fields: [
            field("id", "INT64"), field("name", "STRING"), field("ts", "TIMESTAMP")
        ])
        let types = BigQueryTypeMapper.columnTypeNames(from: schema)
        #expect(types == ["INT64", "STRING", "TIMESTAMP"])
    }

    @Test("REPEATED mode wraps in ARRAY<>")
    func repeatedMode() {
        let schema = BQTableSchema(fields: [field("tags", "STRING", mode: "REPEATED")])
        let types = BigQueryTypeMapper.columnTypeNames(from: schema)
        #expect(types == ["ARRAY<STRING>"])
    }

    @Test("RECORD type formats as STRUCT<>")
    func recordType() {
        let schema = BQTableSchema(fields: [
            field("address", "RECORD", fields: [
                field("city", "STRING"), field("zip", "INT64")
            ])
        ])
        let types = BigQueryTypeMapper.columnTypeNames(from: schema)
        #expect(types == ["STRUCT<city STRING, zip INT64>"])
    }

    @Test("REPEATED RECORD formats as ARRAY<STRUCT<>>")
    func repeatedRecord() {
        let schema = BQTableSchema(fields: [
            field("items", "RECORD", mode: "REPEATED", fields: [field("name", "STRING")])
        ])
        let types = BigQueryTypeMapper.columnTypeNames(from: schema)
        #expect(types == ["ARRAY<STRUCT<name STRING>>"])
    }

    @Test("Empty schema returns empty array")
    func emptySchema() {
        let schema = BQTableSchema(fields: nil)
        #expect(BigQueryTypeMapper.columnTypeNames(from: schema).isEmpty)
    }
}

@Suite("BigQueryTypeMapper - Column Infos")
struct BigQueryTypeMapperColumnInfoTests {
    @Test("Fields map to PluginColumnInfo correctly")
    func basicMapping() {
        let fields = [
            field("id", "INT64", mode: "REQUIRED", description: "Primary ID"),
            field("name", "STRING", mode: "NULLABLE")
        ]
        let infos = BigQueryTypeMapper.columnInfos(from: fields)
        #expect(infos.count == 2)
        #expect(infos[0].name == "id")
        #expect(infos[0].dataType == "INT64")
        #expect(infos[0].isNullable == false)
        #expect(infos[0].isPrimaryKey == false)
        #expect(infos[0].comment == "Primary ID")
        #expect(infos[1].name == "name")
        #expect(infos[1].isNullable == true)
        #expect(infos[1].comment == nil)
    }
}

@Suite("BigQueryTypeMapper - Row Flattening")
struct BigQueryTypeMapperRowTests {
    @Test("String values pass through")
    func stringValues() {
        let schema = BQTableSchema(fields: [field("name", "STRING")])
        let resp = response(rows: [
            BQQueryResponse.BQRow(f: [BQQueryResponse.BQCell(v: .string("Alice"))])
        ], totalRows: "1")
        #expect(BigQueryTypeMapper.flattenRows(from: resp, schema: schema) == [["Alice"]])
    }

    @Test("Null values map to nil")
    func nullValues() {
        let schema = BQTableSchema(fields: [field("val", "STRING")])
        let resp = response(rows: [
            BQQueryResponse.BQRow(f: [BQQueryResponse.BQCell(v: .null)])
        ], totalRows: "1")
        #expect(BigQueryTypeMapper.flattenRows(from: resp, schema: schema) == [[nil]])
    }

    @Test("Timestamp epoch-seconds convert to ISO8601")
    func timestampConversion() {
        let schema = BQTableSchema(fields: [field("ts", "TIMESTAMP")])
        let resp = response(rows: [
            BQQueryResponse.BQRow(f: [BQQueryResponse.BQCell(v: .string("1617235200"))])
        ], totalRows: "1")
        let rows = BigQueryTypeMapper.flattenRows(from: resp, schema: schema)
        let value = rows[0][0]
        #expect(value != nil)
        #expect(value!.contains("2021-03-31") || value!.contains("2021-04-01"))
    }

    @Test("Boolean values normalize to lowercase")
    func booleanConversion() {
        let schema = BQTableSchema(fields: [field("flag", "BOOL")])
        let resp = response(rows: [
            BQQueryResponse.BQRow(f: [BQQueryResponse.BQCell(v: .string("true"))]),
            BQQueryResponse.BQRow(f: [BQQueryResponse.BQCell(v: .string("false"))])
        ], totalRows: "2")
        let rows = BigQueryTypeMapper.flattenRows(from: resp, schema: schema)
        #expect(rows[0][0] == "true")
        #expect(rows[1][0] == "false")
    }

    @Test("STRUCT record flattens to JSON object string")
    func structFlattening() {
        let schema = BQTableSchema(fields: [
            field("addr", "RECORD", fields: [field("city", "STRING"), field("zip", "INT64")])
        ])
        let resp = response(rows: [
            BQQueryResponse.BQRow(f: [
                BQQueryResponse.BQCell(v: .record(
                    BQCellValue.BQRecordValue(f: [
                        BQQueryResponse.BQCell(v: .string("NYC")),
                        BQQueryResponse.BQCell(v: .string("10001"))
                    ])
                ))
            ])
        ], totalRows: "1")
        let value = BigQueryTypeMapper.flattenRows(from: resp, schema: schema)[0][0]
        #expect(value != nil)
        #expect(value!.contains("\"city\""))
        #expect(value!.contains("\"NYC\""))
    }

    @Test("REPEATED array flattens to JSON array string")
    func arrayFlattening() {
        let schema = BQTableSchema(fields: [field("tags", "STRING", mode: "REPEATED")])
        let resp = response(rows: [
            BQQueryResponse.BQRow(f: [
                BQQueryResponse.BQCell(v: .array([.string("red"), .string("blue")]))
            ])
        ], totalRows: "1")
        let value = BigQueryTypeMapper.flattenRows(from: resp, schema: schema)[0][0]
        #expect(value != nil)
        #expect(value!.contains("red"))
        #expect(value!.contains("blue"))
    }

    @Test("Empty response returns empty rows")
    func emptyResponse() {
        let schema = BQTableSchema(fields: [field("id", "INT64")])
        let resp = response(rows: nil)
        #expect(BigQueryTypeMapper.flattenRows(from: resp, schema: schema).isEmpty)
    }
}
