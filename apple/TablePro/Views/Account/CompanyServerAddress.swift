//
//  CompanyServerAddress.swift
//  TablePro
//

import Foundation

// What a person types into Use a Company Server, as the API origin the core runs discovery on. The core checks it
// again; this only turns "tablepro.example.com" into https://tablepro.example.com and refuses what is not an origin.
internal enum CompanyServerAddress {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

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
        case "http" where loopbackHosts.contains(host):
            break
        default:
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        return components.url
    }
}
