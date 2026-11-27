//
//  CompanyServerAddress.swift
//  TablePro
//

import Foundation

// What a person types into Use a Company Server, as the API origin the core runs discovery on. The core checks it
// again; this only turns "tablepro.example.com" into https://tablepro.example.com and refuses what is not an origin.
internal enum CompanyServerAddress {
    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }
        switch scheme {
        case "https":
            break
        // Only a server on this Mac goes without TLS, as in a development stack.
        case "http" where isLoopback(host):
            break
        default:
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        return components.url
    }

    // The hosts the core lets http reach: localhost and RFC 6761's *.localhost, 127.0.0.0/8 and ::1.
    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil } && octets.first == "127"
    }
}
