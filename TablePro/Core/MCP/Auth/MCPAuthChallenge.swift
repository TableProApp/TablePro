import Foundation

public struct MCPAuthChallenge: Sendable, Equatable {
    public let realm: String?
    public let error: String?
    public let errorDescription: String?
    public let scope: [String]

    public init(realm: String? = nil, error: String? = nil, errorDescription: String? = nil, scope: [String] = []) {
        self.realm = realm
        self.error = error
        self.errorDescription = errorDescription
        self.scope = scope
    }

    public static let bearerRealm = MCPAuthChallenge(realm: "TablePro")

    public static func invalidToken(description: String?) -> MCPAuthChallenge {
        MCPAuthChallenge(realm: "TablePro", error: "invalid_token", errorDescription: description)
    }

    public static func insufficientScope(scopes: [String], description: String?) -> MCPAuthChallenge {
        MCPAuthChallenge(
            realm: "TablePro",
            error: "insufficient_scope",
            errorDescription: description,
            scope: scopes
        )
    }

    public var headerValue: String {
        var parameters: [String] = []
        if let realm {
            parameters.append("realm=\"\(Self.escape(realm))\"")
        }
        if let error {
            parameters.append("error=\"\(Self.escape(error))\"")
        }
        if let errorDescription {
            parameters.append("error_description=\"\(Self.escape(errorDescription))\"")
        }
        if !scope.isEmpty {
            parameters.append("scope=\"\(Self.escape(scope.joined(separator: " ")))\"")
        }
        guard !parameters.isEmpty else { return "Bearer" }
        return "Bearer " + parameters.joined(separator: ", ")
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
