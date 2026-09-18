import Foundation

public enum SpannerConfigurationError: Error, Sendable, Equatable {
    case missingField(String)
    case invalidIdentifier(String)
    case invalidEndpoint
    case untrustedEndpoint
    case emulatorRequiresLoopback
    case unknownAuthMethod(String)
}
