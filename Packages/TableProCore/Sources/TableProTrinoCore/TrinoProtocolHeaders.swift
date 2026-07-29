import Foundation

public struct TrinoProtocolHeaders: Sendable, Equatable {
    public let prefix: String

    public init(prefix: String) {
        self.prefix = prefix
    }

    public static let trino = TrinoProtocolHeaders(prefix: "X-Trino-")
    public static let presto = TrinoProtocolHeaders(prefix: "X-Presto-")

    public var user: String { prefix + "User" }
    public var source: String { prefix + "Source" }
    public var catalog: String { prefix + "Catalog" }
    public var schema: String { prefix + "Schema" }
    public var timeZone: String { prefix + "Time-Zone" }
    public var session: String { prefix + "Session" }
    public var role: String { prefix + "Role" }
    public var preparedStatement: String { prefix + "Prepared-Statement" }
    public var transactionId: String { prefix + "Transaction-Id" }
    public var clientInfo: String { prefix + "Client-Info" }
    public var clientTags: String { prefix + "Client-Tags" }
    public var clientCapabilities: String { prefix + "Client-Capabilities" }

    public var setCatalog: String { prefix + "Set-Catalog" }
    public var setSchema: String { prefix + "Set-Schema" }
    public var setSession: String { prefix + "Set-Session" }
    public var clearSession: String { prefix + "Clear-Session" }
    public var setRole: String { prefix + "Set-Role" }
    public var addedPrepare: String { prefix + "Added-Prepare" }
    public var deallocatedPrepare: String { prefix + "Deallocated-Prepare" }
    public var startedTransactionId: String { prefix + "Started-Transaction-Id" }
    public var clearTransactionId: String { prefix + "Clear-Transaction-Id" }
}
