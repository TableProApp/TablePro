import Foundation

// The hosts of a `mongodb://` URI, each with its port written once. An IPv6 address keeps its brackets, so its colons
// never read as the port.
nonisolated enum MongoDBHostList {
    static func uriHosts(_ raw: String, defaultPort: Int) -> String? {
        let entries = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let hosts = entries.compactMap { uriHost(String($0), defaultPort: defaultPort) }
        guard !hosts.isEmpty, hosts.count == entries.count else { return nil }
        return hosts.joined(separator: ",")
    }

    private static func uriHost(_ entry: String, defaultPort: Int) -> String? {
        var port = defaultPort
        if entry.hasPrefix("[") {
            guard let closing = entry.firstIndex(of: "]") else { return nil }
            let address = entry[entry.index(after: entry.startIndex) ..< closing]
            let tail = entry[entry.index(after: closing)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":"), let explicit = Int(tail.dropFirst()) else { return nil }
                port = explicit
            }
            guard isAddress(address), (1 ... 65_535).contains(port) else { return nil }
            return "[\(address)]:\(port)"
        }
        let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count > 2 {
            guard isAddress(Substring(entry)) else { return nil }
            return "[\(entry)]:\(port)"
        }
        if parts.count == 2 {
            guard let explicit = Int(parts[1]) else { return nil }
            port = explicit
        }
        let host = String(parts[0])
        guard !host.isEmpty, (1 ... 65_535).contains(port) else { return nil }
        let encoded = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        return "\(encoded):\(port)"
    }

    private static func isAddress(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0 == ":" || $0 == "." || $0.properties.isASCIIHexDigit }
    }
}
