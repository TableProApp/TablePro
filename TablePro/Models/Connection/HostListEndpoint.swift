//
//  HostListEndpoint.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct HostListEndpoint: Equatable {
    let host: String
    let port: Int

    var entry: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Takes `host`, `host:port`, `[address]:port`, a bare IPv6 address, or a pasted `http://` or
    /// `https://` URL. A URL with no port names 80 or 443, the way the URL itself reads. A path,
    /// credentials or a port outside 1...65535 make the entry invalid rather than being dropped.
    static func parse(_ text: String, defaultPort: Int) -> HostListEndpoint? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var port = defaultPort
        if let schemeEnd = rest.range(of: "://") {
            switch rest[..<schemeEnd.lowerBound].lowercased() {
            case "https": port = 443
            case "http": port = 80
            default: return nil
            }
            rest = rest[schemeEnd.upperBound...]
        }
        if rest.hasSuffix("/") {
            rest = rest.dropLast()
        }
        guard !rest.contains("/"), !rest.contains("@") else { return nil }
        var host = rest
        if rest.hasPrefix("[") {
            guard let closing = rest.firstIndex(of: "]") else { return nil }
            host = rest[rest.index(after: rest.startIndex) ..< closing]
            let tail = rest[rest.index(after: closing)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":"), let explicit = Int(tail.dropFirst()) else { return nil }
                port = explicit
            }
        } else if let lastColon = rest.lastIndex(of: ":"), !rest[..<lastColon].contains(":") {
            host = rest[..<lastColon]
            guard let explicit = Int(rest[rest.index(after: lastColon)...]) else { return nil }
            port = explicit
        }
        guard !host.isEmpty, (1 ... 65_535).contains(port) else { return nil }
        return HostListEndpoint(host: String(host), port: port)
    }

    static func usesHTTPS(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("https://")
    }

    static func parseList(_ raw: String, defaultPort: Int) -> [HostListEndpoint] {
        raw.split(separator: ",").compactMap { parse(String($0), defaultPort: defaultPort) }
    }
}

extension Array where Element == ConnectionField {
    /// The host list that stands in for Host and Port. A list with a visibility rule belongs to
    /// one mode (Redis Sentinel, Redis Cluster) and leaves Host and Port to the other modes.
    var endpointHostList: ConnectionField? {
        first { field in
            guard case .hostList = field.fieldType else { return false }
            return field.section == .connection && field.visibleWhen == nil
        }
    }
}
