//
//  D1ResponseParsingTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("D1 API Response Parsing")
struct D1ResponseParsingTests {

    // MARK: - Local copies of Codable types for testing

    private struct D1ApiResponse<T: Decodable>: Decodable {
        let result: T?
        let success: Bool
        let errors: [D1ApiErrorDetail]?
    }

    private struct D1ApiErrorDetail: Decodable {
        let code: Int?
        let message: String
    }

    private struct D1RawResultPayload: Decodable {
        let results: D1RawResults
        let meta: D1QueryMeta?
        let success: Bool
    }

    private struct D1RawResults: Decodable {
        let columns: [String]?
        let rows: [[D1Value]]?
    }

    private struct D1QueryMeta: Decodable {
        let duration: Double?
        let changes: Int?
        let rowsRead: Int?
        let rowsWritten: Int?

        enum CodingKeys: String, CodingKey {
            case duration, changes
            case rowsRead = "rows_read"
            case rowsWritten = "rows_written"
        }
    }

    private struct D1DatabaseInfo: Decodable {
        let uuid: String
        let name: String
        let createdAt: String?
        let version: String?

        enum CodingKeys: String, CodingKey {
            case uuid, name, version
            case createdAt = "created_at"
        }
    }

    private struct D1ListResponse: Decodable {
        let result: [D1DatabaseInfo]
        let success: Bool
    }

    private enum D1Value: Decodable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        var stringValue: String? {
            switch self {
            case .string(let val): return val
            case .int(let val): return String(val)
            case .double(let val): return String(val)
            case .bool(let val): return val ? "1" : "0"
            case .null: return nil
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let v = try? container.decode(Int.self) { self = .int(v); return }
            if let v = try? container.decode(Double.self) { self = .double(v); return }
            if let v = try? container.decode(Bool.self) { self = .bool(v); return }
            if let v = try? container.decode(String.self) { self = .string(v); return }
            self = .null
        }
    }

    // MARK: - /raw Endpoint Response

    @Test("Parses raw query response with columns and rows")
    func parsesRawResponse() throws {
        let json = """
        {
          "result": [{
            "results": {
              "columns": ["id", "name", "age"],
              "rows": [[1, "Alice", 30], [2, "Bob", null]]
            },
            "meta": {
              "duration": 0.5,
              "changes": 0,
              "rows_read": 2,
              "rows_written": 0
            },
            "success": true
          }],
          "success": true,
          "errors": []
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(D1ApiResponse<[D1RawResultPayload]>.self, from: json)
        #expect(envelope.success)

        guard let results = envelope.result, let first = results.first else {
            Issue.record("Expected non-nil result")
            return
        }

        #expect(first.success)
        #expect(first.results.columns == ["id", "name", "age"])

        guard let rows = first.results.rows else {
            Issue.record("Expected non-nil rows")
            return
        }

        #expect(rows.count == 2)
        #expect(rows[0][0].stringValue == "1")
        #expect(rows[0][1].stringValue == "Alice")
        #expect(rows[0][2].stringValue == "30")
        #expect(rows[1][0].stringValue == "2")
        #expect(rows[1][1].stringValue == "Bob")
        #expect(rows[1][2].stringValue == nil)

        #expect(first.meta?.duration == 0.5)
        #expect(first.meta?.changes == 0)
        #expect(first.meta?.rowsRead == 2)
        #expect(first.meta?.rowsWritten == 0)
    }

    @Test("Parses raw response with empty results")
    func parsesEmptyRawResponse() throws {
        let json = """
        {
          "result": [{
            "results": {
              "columns": [],
              "rows": []
            },
            "meta": {"duration": 0.1, "changes": 0},
            "success": true
          }],
          "success": true
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(D1ApiResponse<[D1RawResultPayload]>.self, from: json)
        guard let first = envelope.result?.first else {
            Issue.record("Expected result")
            return
        }

        #expect(first.results.columns?.isEmpty == true)
        #expect(first.results.rows?.isEmpty == true)
    }

    @Test("Parses mutation response with changes count")
    func parsesMutationResponse() throws {
        let json = """
        {
          "result": [{
            "results": {
              "columns": [],
              "rows": []
            },
            "meta": {
              "duration": 0.3,
              "changes": 5,
              "rows_read": 0,
              "rows_written": 5
            },
            "success": true
          }],
          "success": true
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(D1ApiResponse<[D1RawResultPayload]>.self, from: json)
        guard let first = envelope.result?.first else {
            Issue.record("Expected result")
            return
        }

        #expect(first.meta?.changes == 5)
        #expect(first.meta?.rowsWritten == 5)
    }

    // MARK: - Error Response

    @Test("Parses error response with error details")
    func parsesErrorResponse() throws {
        let json = """
        {
          "result": null,
          "success": false,
          "errors": [
            {"code": 7500, "message": "no such table: nonexistent"}
          ]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(D1ApiResponse<[D1RawResultPayload]>.self, from: json)
        #expect(!envelope.success)
        #expect(envelope.result == nil)
        #expect(envelope.errors?.count == 1)
        #expect(envelope.errors?.first?.code == 7500)
        #expect(envelope.errors?.first?.message == "no such table: nonexistent")
    }

    @Test("Parses error response without error code")
    func parsesErrorWithoutCode() throws {
        let json = """
        {
          "success": false,
          "errors": [{"message": "Something went wrong"}]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(D1ApiResponse<[D1RawResultPayload]>.self, from: json)
        #expect(!envelope.success)
        #expect(envelope.errors?.first?.code == nil)
        #expect(envelope.errors?.first?.message == "Something went wrong")
    }

    // MARK: - Database List Response

    @Test("Parses list databases response")
    func parsesListDatabases() throws {
        let json = """
        {
          "result": [
            {"uuid": "abc-123", "name": "my-db", "created_at": "2025-01-01T00:00:00Z", "version": "production"},
            {"uuid": "def-456", "name": "staging-db", "created_at": "2025-06-15T12:00:00Z", "version": "production"}
          ],
          "success": true
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(D1ListResponse.self, from: json)
        #expect(response.success)
        #expect(response.result.count == 2)
        #expect(response.result[0].uuid == "abc-123")
        #expect(response.result[0].name == "my-db")
        #expect(response.result[0].createdAt == "2025-01-01T00:00:00Z")
        #expect(response.result[0].version == "production")
        #expect(response.result[1].uuid == "def-456")
        #expect(response.result[1].name == "staging-db")
    }

    @Test("Parses database details response (single object)")
    func parsesDatabaseDetails() throws {
        let json = """
        {
          "result": {"uuid": "abc-123", "name": "my-db", "version": "production"},
          "success": true
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(D1ApiResponse<D1DatabaseInfo>.self, from: json)
        #expect(envelope.success)
        guard let db = envelope.result else {
            Issue.record("Expected result")
            return
        }
        #expect(db.uuid == "abc-123")
        #expect(db.name == "my-db")
        #expect(db.version == "production")
    }

    @Test("Parses database info with missing optional fields")
    func parsesDatabaseInfoMissingOptionals() throws {
        let json = """
        {
          "result": [{"uuid": "abc-123", "name": "my-db"}],
          "success": true
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(D1ListResponse.self, from: json)
        #expect(response.result[0].createdAt == nil)
        #expect(response.result[0].version == nil)
    }

    // MARK: - QueryMeta snake_case Decoding

    @Test("QueryMeta decodes snake_case fields correctly")
    func queryMetaSnakeCase() throws {
        let json = """
        {"duration": 1.5, "changes": 3, "rows_read": 100, "rows_written": 3}
        """.data(using: .utf8)!

        let meta = try JSONDecoder().decode(D1QueryMeta.self, from: json)
        #expect(meta.duration == 1.5)
        #expect(meta.changes == 3)
        #expect(meta.rowsRead == 100)
        #expect(meta.rowsWritten == 3)
    }

    @Test("QueryMeta handles missing optional fields")
    func queryMetaMissingFields() throws {
        let json = "{}".data(using: .utf8)!

        let meta = try JSONDecoder().decode(D1QueryMeta.self, from: json)
        #expect(meta.duration == nil)
        #expect(meta.changes == nil)
        #expect(meta.rowsRead == nil)
        #expect(meta.rowsWritten == nil)
    }
}
