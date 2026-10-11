//
//  ElasticsearchNodes.swift
//  ElasticsearchDriverPlugin
//

import Foundation
import TableProPluginKit

internal struct ElasticsearchNode: Equatable, Sendable {
    let baseURL: URL
    let name: String
}

internal enum ElasticsearchNodes {
    static let hostsField = "esHosts"
    static let defaultPort = 9_200

    /// A tunnel clears the host list and points Host and Port at its local forward, so an empty
    /// list falls back to them.
    static func nodes(config: DriverConnectionConfig) -> [ElasticsearchNode] {
        nodes(
            hostList: config.additionalFields[hostsField],
            host: config.host,
            port: config.port,
            useTLS: config.ssl.isEnabled
        )
    }

    static func nodes(hostList: String?, host: String, port: Int, useTLS: Bool) -> [ElasticsearchNode] {
        let listed = (hostList ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard listed.isEmpty else {
            return listed.compactMap { node(from: $0, defaultPort: defaultPort, useTLS: useTLS) }
        }
        let fallback = node(
            from: host.isEmpty ? "localhost" : host,
            defaultPort: port > 0 ? port : defaultPort,
            useTLS: useTLS
        )
        return fallback.map { [$0] } ?? []
    }

    /// The connection form's host-list grammar. An app that predates the plugin stores the rows as
    /// typed, so a pasted URL reaches this parser too, and its `https://` always means TLS.
    static func node(from entry: String, defaultPort: Int, useTLS: Bool) -> ElasticsearchNode? {
        var rest = Substring(entry.trimmingCharacters(in: .whitespaces))
        var port = defaultPort
        var tls = useTLS
        if let schemeEnd = rest.range(of: "://") {
            switch rest[..<schemeEnd.lowerBound].lowercased() {
            case "https":
                tls = true
                port = 443
            case "http":
                port = 80
            default:
                return nil
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
        let name = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        guard let url = URL(string: "\(tls ? "https" : "http")://\(name)") else { return nil }
        return ElasticsearchNode(baseURL: url, name: name)
    }
}

internal enum ElasticsearchFailover {
    /// Failures URLSession reports before any byte of the request is written, so the request can
    /// go to another node even when it changes data. A timeout or a lost connection can come after
    /// the node received it.
    static func neverSent(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    /// A read goes to the next node after any transport failure but a timeout, which a slow search
    /// would otherwise turn into one run per node.
    static func resends(after code: URLError.Code, isRead: Bool) -> Bool {
        neverSent(code) || (isRead && code != .timedOut && code != .cancelled)
    }

    static func nodeUnavailable(statusCode: Int) -> Bool {
        statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    static func isRead(method: String) -> Bool {
        let upper = method.uppercased()
        return upper == "GET" || upper == "HEAD"
    }
}
