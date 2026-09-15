import Foundation

public enum GoogleOAuthCallback: Sendable, Equatable {
    case code(String)
    case denied(String)
    case ignore

    static let unknownDenialReason = "unknown"

    public static func parse(requestHead: Data, expectedState: String) -> GoogleOAuthCallback {
        parse(requestHead: decodedHead(requestHead), expectedState: expectedState)
    }

    private static func decodedHead(_ bytes: Data) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    public static func parse(requestHead: String, expectedState: String) -> GoogleOAuthCallback {
        guard !expectedState.isEmpty,
              let target = requestTarget(requestHead),
              let components = URLComponents(string: target),
              components.host == nil,
              components.path == "/"
        else {
            return .ignore
        }
        let items = components.queryItems ?? []
        guard let state = singleValue(named: "state", in: items), constantTimeEquals(state, expectedState) else {
            return .ignore
        }
        if let code = singleValue(named: "code", in: items), !code.isEmpty {
            return .code(code)
        }
        if let error = singleValue(named: "error", in: items), !error.isEmpty {
            return .denied(GoogleOAuthErrorCode.sanitized(error) ?? unknownDenialReason)
        }
        return .ignore
    }

    private static func requestTarget(_ head: String) -> String? {
        let scalars = head.unicodeScalars
        let lineEnd = scalars.firstIndex(of: "\n") ?? scalars.endIndex
        var requestLine = String(scalars[scalars.startIndex..<lineEnd])
        if requestLine.unicodeScalars.last == "\r" {
            requestLine.unicodeScalars.removeLast()
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/"), parts[1].hasPrefix("/") else {
            return nil
        }
        return String(parts[1])
    }

    private static func singleValue(named name: String, in items: [URLQueryItem]) -> String? {
        let matches = items.filter { $0.name == name }
        guard matches.count == 1 else { return nil }
        return matches[0].value
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
