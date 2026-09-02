import Foundation

/// Reads the execution figures ClickHouse sends back in `X-ClickHouse-Summary`.
///
/// The header is a JSON object whose numbers are quoted strings, and its member set has grown over
/// releases: `elapsed_ns` only appears on servers new enough to send it. Every field is therefore
/// optional, and a header that cannot be read at all yields nothing rather than a zero, because a
/// zero would read as a query that took no time.
public enum ClickHouseSummaryParser {
    public struct Summary: Sendable, Equatable {
        public let elapsed: TimeInterval?
        public let readRows: UInt64?
        public let readBytes: UInt64?

        public init(elapsed: TimeInterval?, readRows: UInt64?, readBytes: UInt64?) {
            self.elapsed = elapsed
            self.readRows = readRows
            self.readBytes = readBytes
        }
    }

    public static let headerName = "X-ClickHouse-Summary"

    public static func parse(headers: [String: String]) -> Summary? {
        guard let raw = value(forHeader: headerName, in: headers) else { return nil }
        return parse(headerValue: raw)
    }

    public static func parse(headerValue: String) -> Summary? {
        guard let data = headerValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let elapsedNanoseconds = unsignedValue(object["elapsed_ns"])
        let summary = Summary(
            elapsed: elapsedNanoseconds.map { TimeInterval($0) / 1_000_000_000 },
            readRows: unsignedValue(object["read_rows"]),
            readBytes: unsignedValue(object["read_bytes"])
        )
        guard summary.elapsed != nil || summary.readRows != nil || summary.readBytes != nil else {
            return nil
        }
        return summary
    }

    /// HTTP header names are case-insensitive and `HTTPURLResponse` hands them back in whatever
    /// case the server used, so the lookup cannot be a plain subscript.
    private static func value(forHeader name: String, in headers: [String: String]) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }

    private static func unsignedValue(_ raw: Any?) -> UInt64? {
        if let text = raw as? String { return UInt64(text) }
        if let number = raw as? NSNumber { return UInt64(exactly: number.uint64Value) }
        return nil
    }
}
