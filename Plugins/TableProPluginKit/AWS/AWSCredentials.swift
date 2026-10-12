import Foundation

public struct AWSCredentials: Sendable, Equatable {
    public let accessKeyId: String
    public let secretAccessKey: String
    public let sessionToken: String?
    public let expiration: Date?

    public init(
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String?,
        expiration: Date? = nil
    ) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }

    public func isExpired(asOf now: Date = Date(), safetyWindow: TimeInterval = 300) -> Bool {
        guard let expiration else { return false }
        return expiration.timeIntervalSince(now) <= safetyWindow
    }
}

extension AWSCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "AWSCredentials(accessKeyId: \(redactedAccessKeyId), redacted)"
    }

    public var debugDescription: String { description }

    private var redactedAccessKeyId: String {
        guard accessKeyId.count > 4 else { return "…" }
        return "\(accessKeyId.prefix(4))…"
    }
}
