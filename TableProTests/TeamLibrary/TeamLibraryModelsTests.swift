//
//  TeamLibraryModelsTests.swift
//  TablePro
//
//  Tests the team library wire format: snake_case top-level keys, and the embedded connection payload
//  keeping its own key encoding (no recursive key strategy corrupting it).
//

import Foundation
@testable import TablePro
import TableProImport
import Testing

@Suite("TeamLibraryModels")
struct TeamLibraryModelsTests {
    @Test("pull response decodes the snake_case wire format")
    func decodesPullResponse() throws {
        let json = """
        {
          "connections": [
            {"id":"01ABC","source_connection_id":"11111111-1111-1111-1111-111111111111","payload":{"name":"Prod","host":"db","port":5432,"database":"app","username":"deploy","type":"PostgreSQL"},"published_by":"owner@example.com","published_at":"2026-07-08T00:00:00Z"}
          ],
          "query_folders": [
            {"client_id":"22222222-2222-2222-2222-222222222222","parent_client_id":null,"name":"ETL","sort_order":0,"published_by":"owner@example.com"}
          ],
          "queries": [
            {"client_id":"33333333-3333-3333-3333-333333333333","folder_client_id":"22222222-2222-2222-2222-222222222222","connection_client_id":null,"name":"Recent","query":"select 1","keyword":null,"sort_order":0,"published_by":"owner@example.com"}
          ],
          "fetched_at":"2026-07-08T00:00:00Z"
        }
        """

        let response = try JSONDecoder().decode(TeamLibraryPullResponse.self, from: Data(json.utf8))

        #expect(response.connections.count == 1)
        #expect(response.connections[0].payload.name == "Prod")
        #expect(response.connections[0].payload.type == "PostgreSQL")
        #expect(response.connections[0].publishedBy == "owner@example.com")
        #expect(response.queryFolders[0].name == "ETL")
        #expect(response.queries[0].query == "select 1")
    }

    @Test("publish request encodes snake_case keys and preserves the payload encoding")
    func encodesPublishRequest() throws {
        let payloadJson = """
        {"name":"Prod","host":"db","port":5432,"database":"app","username":"deploy","type":"PostgreSQL"}
        """
        let exportable = try JSONDecoder().decode(ExportableConnection.self, from: Data(payloadJson.utf8))

        let request = TeamLibraryPublishRequest(
            licenseKey: "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE",
            machineId: String(repeating: "a", count: 64),
            connections: [TeamLibraryConnectionPayload(sourceConnectionId: "11111111-1111-1111-1111-111111111111", payload: exportable)],
            queryFolders: [],
            queries: []
        )

        let string = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)

        #expect(string.contains("\"license_key\""))
        #expect(string.contains("\"machine_id\""))
        #expect(string.contains("\"query_folders\""))
        #expect(string.contains("\"source_connection_id\""))
        #expect(string.contains("\"name\":\"Prod\""))
    }
}
