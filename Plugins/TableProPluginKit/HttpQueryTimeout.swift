import Foundation

public struct HttpQueryTimeout: Sendable, Equatable {
    private static let maximumSeconds = Int(Int32.max) / 1_000

    public static let bootstrapSeconds: Int = 60
    public static let defaultGraceSeconds: Int = 30
    public static let resourceCeilingSeconds: Int = 3_600

    public let serverTimeoutSeconds: Int
    public let graceSeconds: Int

    public init(
        serverTimeoutSeconds: Int = Self.bootstrapSeconds,
        graceSeconds: Int = Self.defaultGraceSeconds
    ) {
        self.serverTimeoutSeconds = min(serverTimeoutSeconds, Self.maximumSeconds)
        self.graceSeconds = min(max(graceSeconds, 0), Self.maximumSeconds)
    }

    public var requestTimeoutInterval: TimeInterval {
        guard serverTimeoutSeconds > 0 else {
            return TimeInterval(Self.resourceCeilingSeconds)
        }
        return TimeInterval(serverTimeoutSeconds + graceSeconds)
    }

    public static var sessionResourceTimeout: TimeInterval {
        TimeInterval(resourceCeilingSeconds)
    }

    public static var sessionBootstrapRequestTimeout: TimeInterval {
        TimeInterval(bootstrapSeconds)
    }
}
