import Foundation

public struct MCPListPage<Element> {
    public let items: [Element]
    public let nextCursor: String?

    public init(items: [Element], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum MCPListPagination {
    public static let defaultPageSize = 50

    public static func cursorArgument(in params: JsonValue?) throws -> String? {
        guard let value = params?["cursor"], !value.isNull else { return nil }
        guard case .string(let cursor) = value, !cursor.isEmpty else {
            throw MCPProtocolError.invalidParams(detail: "cursor must be a non-empty string")
        }
        return cursor
    }

    public static func page<Element>(
        _ items: [Element],
        cursor: String?,
        method: String,
        pageSize: Int = defaultPageSize
    ) throws -> MCPListPage<Element> {
        let offset = try cursor.map { try decodeCursor($0, method: method) } ?? 0
        guard offset <= items.count else {
            throw MCPProtocolError.invalidParams(detail: "cursor is no longer valid")
        }
        let end = min(offset + max(pageSize, 1), items.count)
        let nextCursor = end < items.count ? encodeCursor(offset: end, method: method) : nil
        return MCPListPage(items: Array(items[offset ..< end]), nextCursor: nextCursor)
    }

    public static func encodeCursor(offset: Int, method: String) -> String {
        let encoded = Data("\(method)#\(offset)".utf8).base64EncodedString()
        return encoded
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeCursor(_ cursor: String, method: String) throws -> Int {
        guard let data = Data(base64Encoded: paddedBase64(cursor)),
              let decoded = String(data: data, encoding: .utf8) else {
            throw MCPProtocolError.invalidParams(detail: "cursor is not a valid pagination cursor")
        }
        let parts = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == method else {
            throw MCPProtocolError.invalidParams(detail: "cursor belongs to a different request")
        }
        guard let offset = Int(parts[1]), offset >= 0 else {
            throw MCPProtocolError.invalidParams(detail: "cursor is not a valid pagination cursor")
        }
        return offset
    }

    private static func paddedBase64(_ value: String) -> String {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return normalized
    }
}
