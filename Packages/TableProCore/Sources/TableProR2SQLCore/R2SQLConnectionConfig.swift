import Foundation

public struct R2SQLConnectionConfig: Sendable, Equatable {
    public static let queryHost = "api.sql.cloudflarestorage.com"

    public let accountId: String
    public let bucket: String
    public let token: String
    public let defaultNamespace: String
    public let timeoutSeconds: Int

    public init(
        accountId: String,
        bucket: String,
        token: String,
        defaultNamespace: String = "",
        timeoutSeconds: Int = 60
    ) {
        self.accountId = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token
        self.defaultNamespace = defaultNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeoutSeconds = timeoutSeconds
    }

    public var warehouse: String {
        "\(accountId)_\(bucket)"
    }

    public var queryURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.queryHost
        components.path = "/api/v1/accounts/\(accountId)/r2-sql/query/\(bucket)"
        return components.url
    }

    public func validate() -> R2SQLError? {
        if accountId.isEmpty {
            return .configuration(R2SQLErrorText.missingAccountId)
        }
        if bucket.isEmpty {
            return .configuration(R2SQLErrorText.missingBucket)
        }
        if token.isEmpty {
            return .configuration(R2SQLErrorText.missingToken)
        }
        if queryURL == nil {
            return .configuration(R2SQLErrorText.invalidEndpoint)
        }
        return nil
    }
}

public enum R2SQLWarehouse {
    public static func split(_ warehouse: String) -> (accountId: String, bucket: String)? {
        guard let separator = warehouse.firstIndex(of: "_") else { return nil }
        let accountId = String(warehouse[warehouse.startIndex..<separator])
        let bucket = String(warehouse[warehouse.index(after: separator)...])
        guard !accountId.isEmpty, !bucket.isEmpty else { return nil }
        return (accountId, bucket)
    }
}
