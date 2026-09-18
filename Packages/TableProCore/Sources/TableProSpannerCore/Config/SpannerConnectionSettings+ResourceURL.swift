import Foundation

internal extension SpannerConnectionSettings {
    private static let pathSegmentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    func resourceURL(_ resourceName: String, suffix: String? = nil, verb: String? = nil) throws -> URL {
        var segments = try Self.encodedSegments(resourceName)
        if let suffix {
            segments.append(contentsOf: try Self.encodedSegments(suffix))
        }
        var path = segments.joined(separator: "/")
        if let verb {
            path += ":\(verb)"
        }
        guard let url = URL(string: "\(Self.baseString(endpoint))/v1/\(path)") else {
            throw SpannerTransportError.invalidResponse
        }
        return url
    }

    func databaseURL(suffix: String? = nil) throws -> URL {
        try resourceURL(databasePath, suffix: suffix)
    }

    private static func baseString(_ endpoint: URL) -> String {
        var text = endpoint.absoluteString
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    private static func encodedSegments(_ resourceName: String) throws -> [String] {
        let segments = resourceName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty else { throw SpannerTransportError.invalidResponse }
        return try segments.map { segment in
            guard !segment.isEmpty, segment != ".", segment != ".." else {
                throw SpannerTransportError.invalidResponse
            }
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: pathSegmentCharacters) else {
                throw SpannerTransportError.invalidResponse
            }
            return encoded
        }
    }
}
