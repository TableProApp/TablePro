import Foundation

public enum TrinoAuth: Sendable, Equatable {
    case none
    case basic(password: String)
    case jwt(token: String)
}

public struct TrinoTLSOptions: Sendable, Equatable {
    public enum VerificationMode: Sendable, Equatable {
        case full
        case caOnly
        case insecure
    }

    public var mode: VerificationMode
    public var caCertificatePath: String
    public var clientCertificatePath: String
    public var clientKeyPath: String

    public init(
        mode: VerificationMode = .full,
        caCertificatePath: String = "",
        clientCertificatePath: String = "",
        clientKeyPath: String = ""
    ) {
        self.mode = mode
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
    }

    public static let systemDefault = TrinoTLSOptions(mode: .full)
    public static let insecure = TrinoTLSOptions(mode: .insecure)
}

public struct TrinoClientConfig: Sendable {
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var tls: TrinoTLSOptions
    public var user: String
    public var source: String
    public var catalog: String?
    public var schema: String?
    public var timeZone: String?
    public var auth: TrinoAuth
    public var clientTags: [String]
    public var protocolHeaders: TrinoProtocolHeaders
    public var requestTimeoutSeconds: Int

    public init(
        host: String,
        port: Int = 8_080,
        useTLS: Bool = false,
        tls: TrinoTLSOptions = .systemDefault,
        user: String,
        source: String = "TablePro",
        catalog: String? = nil,
        schema: String? = nil,
        timeZone: String? = nil,
        auth: TrinoAuth = .none,
        clientTags: [String] = [],
        protocolHeaders: TrinoProtocolHeaders = .trino,
        requestTimeoutSeconds: Int = 60
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.tls = tls
        self.user = user
        self.source = source
        self.catalog = catalog
        self.schema = schema
        self.timeZone = timeZone
        self.auth = auth
        self.clientTags = clientTags
        self.protocolHeaders = protocolHeaders
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    public var scheme: String { useTLS ? "https" : "http" }

    public var statementURL: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = "/v1/statement"
        return components.url
    }

    public var authorizationHeader: String? {
        switch auth {
        case .none:
            return nil
        case .basic(let password):
            let credentials = "\(user):\(password)"
            return "Basic \(Data(credentials.utf8).base64EncodedString())"
        case .jwt(let token):
            return "Bearer \(token)"
        }
    }
}
