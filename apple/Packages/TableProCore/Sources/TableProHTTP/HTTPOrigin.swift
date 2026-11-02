import Foundation

public struct HTTPOrigin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.user == nil, components.password == nil,
              let encodedHost = components.percentEncodedHost,
              // A decoded `/`, `@` or `#` in the host would name a different server once the text is parsed again.
              !encodedHost.contains("%")
        else {
            return nil
        }
        var host = encodedHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = components.port ?? Self.defaultPort(for: scheme)
    }

    public var isLoopback: Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port == Self.defaultPort(for: scheme) ? nil : port
        components.path = "/"
        return components.url
    }

    public func followServerURL(_ value: String) throws -> URL {
        guard let base = url,
              let resolved = URL(string: value, relativeTo: base)?.absoluteURL,
              HTTPOrigin(resolved) == self
        else {
            throw CredentialedHTTPError.crossOrigin(value)
        }
        return resolved
    }

    private static func defaultPort(for scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }
}
