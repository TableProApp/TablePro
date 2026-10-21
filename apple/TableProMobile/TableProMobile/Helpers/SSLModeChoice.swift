import TableProModels

// The model stores the Mac's Preferred as .require plus isMacPreferred.
nonisolated enum SSLModeChoice: Hashable, Sendable {
    case disable
    case preferred
    case require
    case verifyCa
    case verifyFull

    init(_ configuration: SSLConfiguration) {
        self = configuration.isMacPreferred ? .preferred : Self(configuration.mode)
    }

    init(_ mode: SSLConfiguration.SSLMode) {
        switch mode {
        case .disable: self = .disable
        case .require: self = .require
        case .verifyCa: self = .verifyCa
        case .verifyFull: self = .verifyFull
        }
    }

    var mode: SSLConfiguration.SSLMode {
        switch self {
        case .disable: .disable
        case .preferred, .require: .require
        case .verifyCa: .verifyCa
        case .verifyFull: .verifyFull
        }
    }

    func applied(to configuration: SSLConfiguration) -> SSLConfiguration {
        switch self {
        case .preferred:
            return Self.rebuilt(configuration, isMacPreferred: true)
        // The flag has no setter, and .require over .require fires no didSet to clear it.
        case .require where configuration.isMacPreferred:
            return Self.rebuilt(configuration, isMacPreferred: false)
        default:
            var configuration = configuration
            configuration.mode = mode
            return configuration
        }
    }

    private static func rebuilt(_ configuration: SSLConfiguration, isMacPreferred: Bool) -> SSLConfiguration {
        SSLConfiguration(
            mode: .require,
            caCertificatePath: configuration.caCertificatePath,
            clientCertificatePath: configuration.clientCertificatePath,
            clientKeyPath: configuration.clientKeyPath,
            isMacPreferred: isMacPreferred
        )
    }
}
