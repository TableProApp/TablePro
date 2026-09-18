import Foundation

public enum WeaviatePathEncoding {
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_")
        return set
    }()

    public static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// A console line carries its own query string (`GET /v1/objects?class=Article`), so the path
    /// is parsed rather than assigned whole: `URLComponents.path` percent-encodes `?` into `%3F`
    /// and sends the request to a path that does not exist.
    public static func resolve(_ path: String, query: [String: String] = [:], against base: URL) -> URL? {
        guard path.hasPrefix("/"), !path.contains("://") else { return nil }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let requested = URLComponents(string: path)
        else { return nil }
        components.percentEncodedPath = requested.percentEncodedPath
        var items = requested.queryItems ?? []
        items += query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}
