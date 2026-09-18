import Foundation

public struct GoogleOAuthClient: Sendable, Equatable {
    public let clientId: String
    public let clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }

    public static let tokenEndpoint = GoogleStaticURL.make("https://oauth2.googleapis.com/token")
    public static let authorizationEndpoint = GoogleStaticURL.make("https://accounts.google.com/o/oauth2/v2/auth")
    public static let cloudPlatformScope = "https://www.googleapis.com/auth/cloud-platform"
}

extension GoogleOAuthClient: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "GoogleOAuthClient(clientId: \(clientId), clientSecret: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

internal enum GoogleStaticURL {
    static func make(_ literal: StaticString) -> URL {
        guard let url = URL(string: "\(literal)") else {
            preconditionFailure("A static Google endpoint literal did not form a URL")
        }
        return url
    }
}
