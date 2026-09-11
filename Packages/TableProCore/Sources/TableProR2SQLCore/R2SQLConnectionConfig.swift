import Foundation

public struct R2SQLConnectionConfig: Sendable, Equatable {
    public static let queryHost = "api.sql.cloudflarestorage.com"

    public let accountId: String
    public let bucket: String
    public let token: String

    public init(accountId: String, bucket: String, token: String) {
        self.accountId = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var queryURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.queryHost
        components.path = "/api/v1/accounts/\(accountId)/r2-sql/query/\(bucket)"
        return components.url
    }

    public func validated() throws -> URL {
        if accountId.isEmpty { throw R2SQLError.configuration("Enter the Cloudflare account ID.") }
        if bucket.isEmpty { throw R2SQLError.configuration("Enter the R2 bucket name.") }
        if token.isEmpty { throw R2SQLError.configuration("Enter a Cloudflare API token.") }
        guard let url = queryURL else {
            throw R2SQLError.configuration("The account ID or bucket name is not valid in a URL.")
        }
        return url
    }
}
