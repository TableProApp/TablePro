//
//  ShareCreateRequest.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

// POST /v2/shares with a body written here: the generated client's JSONEncoder cannot write a number with more digits
// than a Double holds, nor keep a JSON column's key order, and a snapshot needs both.
internal struct ShareCreateRequest: Sendable {
    let serverURL: URL
    let transport: any ClientTransport
    let middlewares: [any ClientMiddleware]

    private static let operationID = "create-share"
    private static let maxResponseBytes = 1_048_576

    func send(_ body: Data) async throws -> (status: Int, contentType: String?, body: Data) {
        var request = HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/shares")
        request.headerFields[.contentType] = "application/json; charset=utf-8"
        request.headerFields[.accept] = "application/json, application/problem+json"

        let transport = transport
        var next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?) = { request, body, url in
            try await transport.send(request, body: body, baseURL: url, operationID: Self.operationID)
        }
        for middleware in middlewares.reversed() {
            let inner = next
            next = { request, body, url in
                try await middleware.intercept(request, body: body, baseURL: url, operationID: Self.operationID, next: inner)
            }
        }
        let (response, responseBody) = try await next(request, HTTPBody(body), serverURL)
        var data = Data()
        if let responseBody {
            data = try await Data(collecting: responseBody, upTo: Self.maxResponseBytes)
        }
        return (response.status.code, response.headerFields[.contentType], data)
    }
}

// The create body as the contract names it (api/v2.json, CreateShareBody).
internal enum ShareBodyWriter {
    // The contract's maxLength for a dialect, and for a column's name and type, in Unicode scalars.
    static let dialectLimit = 40
    static let columnTextLimit = 256

    static func body(_ draft: ShareDraft) -> Data {
        var json = "{"
        var first = true
        func field(_ name: String, _ value: String) {
            json += (first ? "" : ",") + quoted(name) + ":" + value
            first = false
        }
        field("kind", quoted(draft.kind.rawValue))
        field("sql", quoted(draft.sql))
        if !draft.title.isEmpty { field("title", quoted(draft.title)) }
        if let note = draft.note { field("note", quoted(note)) }
        if let dialect = draft.dialect { field("dialect", quoted(clipped(dialect, to: dialectLimit))) }
        field("expiry", quoted(draft.expiry.rawValue))
        if let hidesSQL = draft.hidesSQL { field("hide_sql", hidesSQL ? "true" : "false") }
        if let allowsDownload = draft.allowsDownload { field("allow_download", allowsDownload ? "true" : "false") }
        if let password = draft.password { field("password", quoted(password)) }
        if let teamID = draft.teamID { field("team_id", quoted(teamID)) }
        if let snapshot = draft.snapshot { field("snapshot", self.snapshot(snapshot)) }
        json += "}"
        return Data(json.utf8)
    }

    static func snapshot(_ snapshot: ShareSnapshot) -> String {
        let columns = snapshot.columns.map { column in
            var object = "{\"name\":" + quoted(clipped(column.name, to: columnTextLimit))
            if let type = column.type {
                object += ",\"type\":" + quoted(clipped(type, to: columnTextLimit))
            }
            return object + "}"
        }
        let rows = snapshot.rows.map { row in "[" + row.map(cell).joined(separator: ",") + "]" }
        var json = "{\"columns\":[" + columns.joined(separator: ",") + "],\"rows\":[" + rows.joined(separator: ",") + "]"
        // The count when more rows exist than were sent; more_rows when they exist and nobody counted them.
        if let total = snapshot.rowCount {
            if total > snapshot.rows.count {
                json += ",\"row_count\":\(total)"
            }
        } else {
            json += ",\"more_rows\":true"
        }
        return json + "}"
    }

    static func cell(_ cell: ShareCell) -> String {
        switch cell {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let token), .document(let token): return token
        case .string(let text): return quoted(text)
        case .array(let cells): return "[" + cells.map(self.cell).joined(separator: ",") + "]"
        }
    }

    static func quoted(_ text: String) -> String {
        var result = "\""
        result.unicodeScalars.reserveCapacity(text.unicodeScalars.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }
}
