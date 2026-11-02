import Foundation
import TableProHTTP

public struct SnowflakeAccount: Hashable, Sendable {
    public let host: String
    public let origin: HTTPOrigin
    // ACCOUNT_NAME and the JWT issuer: the locator or org-account, without region or cloud.
    public let name: String
    private let segments: [String]
    private let domain: String

    private static let domains = ["snowflakecomputing.com", "snowflakecomputing.cn"]

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostText: String
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  components.scheme?.lowercased() == "https",
                  components.user == nil, components.password == nil,
                  components.port == nil,
                  components.path.isEmpty || components.path == "/",
                  components.query == nil, components.fragment == nil,
                  let host = components.host
            else {
                return nil
            }
            hostText = host.lowercased()
        } else {
            hostText = trimmed.lowercased()
        }

        var identifier = hostText
        var domain = Self.domains[0]
        if let named = Self.domains.first(where: { hostText.hasSuffix("." + $0) }) {
            identifier = String(hostText.dropLast(named.count + 1))
            domain = named
        } else if trimmed.contains("://") {
            return nil
        }
        let segments = identifier.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(segments.count), segments.allSatisfy(Self.isSegment) else { return nil }

        let host = "\(identifier).\(domain)"
        var built = URLComponents()
        built.scheme = "https"
        built.host = host
        guard let url = built.url, let origin = HTTPOrigin(url), origin.host == host else { return nil }

        self.host = host
        self.origin = origin
        self.name = segments[0].uppercased()
        self.segments = segments
        self.domain = domain
    }

    public func tokenKey(user: String) -> String {
        "\(host)|\(user.uppercased())"
    }

    // The old key was the text before the first dot, which acme and acme.us-east-2.aws shared: only a bare identifier maps back to one host.
    public func legacyTokenKey(user: String) -> String? {
        guard segments.count == 1, domain == Self.domains[0] else { return nil }
        return "\(name).\(user.uppercased())"
    }

    private static func isSegment(_ segment: String) -> Bool {
        segment.range(of: #"^[a-z0-9][a-z0-9_-]{0,62}$"#, options: .regularExpression) != nil
    }
}
