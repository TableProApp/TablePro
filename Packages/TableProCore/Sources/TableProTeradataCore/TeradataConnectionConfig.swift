import Foundation

public enum TeradataLogMech: String, Sendable {
    case td2 = "TD2"
    case ldap = "LDAP"
    case krb5 = "KRB5"
    case jwt = "JWT"
    case tdnego = "TDNEGO"
}

public enum TeradataTransactionMode: String, Sendable {
    case `default` = "DEFAULT"
    case ansi = "ANSI"
    case tera = "TERA"

    var semanticsByte: UInt8 {
        switch self {
        case .default: return 0x44
        case .ansi: return 0x41
        case .tera: return 0x54
        }
    }
}

public struct TeradataTLSOptions: Sendable {
    public var enabled: Bool
    public var allowPlaintextFallback: Bool
    public var verifiesCertificate: Bool
    public var verifiesHostname: Bool
    public var caCertificatePath: String
    public var modeLabel: String
    public var httpsPort: UInt16
    public var webSocketPath: String

    public init(
        enabled: Bool = false,
        allowPlaintextFallback: Bool = false,
        verifiesCertificate: Bool = false,
        verifiesHostname: Bool = false,
        caCertificatePath: String = "",
        modeLabel: String = "DISABLE",
        httpsPort: UInt16 = 443,
        webSocketPath: String = "/gateway"
    ) {
        self.enabled = enabled
        self.allowPlaintextFallback = allowPlaintextFallback
        self.verifiesCertificate = verifiesCertificate
        self.verifiesHostname = verifiesHostname
        self.caCertificatePath = caCertificatePath
        self.modeLabel = modeLabel
        self.httpsPort = httpsPort
        self.webSocketPath = webSocketPath
    }

    public static let disabled = TeradataTLSOptions()
}

public struct TeradataConnectionConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var password: String
    public var database: String?
    public var account: String?
    public var logMech: TeradataLogMech
    public var transactionMode: TeradataTransactionMode
    public var tls: TeradataTLSOptions
    public var connectTimeoutMilliseconds: Int

    public var connectTimeoutSeconds: Int {
        get { (connectTimeoutMilliseconds + 999) / 1_000 }
        set { connectTimeoutMilliseconds = Self.milliseconds(fromSeconds: newValue) }
    }

    public init(
        host: String,
        port: UInt16 = 1_025,
        username: String,
        password: String,
        database: String? = nil,
        account: String? = nil,
        logMech: TeradataLogMech = .td2,
        transactionMode: TeradataTransactionMode = .default,
        tls: TeradataTLSOptions = .disabled,
        connectTimeoutSeconds: Int = 20
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.account = account
        self.logMech = logMech
        self.transactionMode = transactionMode
        self.tls = tls
        connectTimeoutMilliseconds = Self.milliseconds(fromSeconds: connectTimeoutSeconds)
    }

    public init(
        host: String,
        port: UInt16 = 1_025,
        username: String,
        password: String,
        database: String? = nil,
        account: String? = nil,
        logMech: TeradataLogMech = .td2,
        transactionMode: TeradataTransactionMode = .default,
        tls: TeradataTLSOptions = .disabled,
        connectTimeoutMilliseconds: Int
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.account = account
        self.logMech = logMech
        self.transactionMode = transactionMode
        self.tls = tls
        self.connectTimeoutMilliseconds = Self.clampMilliseconds(Int64(connectTimeoutMilliseconds))
    }

    private static func clampMilliseconds(_ value: Int64) -> Int {
        Int(min(max(value, 1), 3_600_000))
    }

    private static func milliseconds(fromSeconds seconds: Int) -> Int {
        let multiplied = Int64(seconds).multipliedReportingOverflow(by: 1_000)
        let milliseconds = multiplied.overflow ? (seconds > 0 ? Int64.max : Int64.min) : multiplied.partialValue
        return clampMilliseconds(milliseconds)
    }
}

public struct TeradataColumn: Sendable {
    public let name: String
    public let typeCode: UInt16
    public let dataLength: Int

    public var baseTypeCode: UInt16 { typeCode & 0xFFFE }
    public var isNullable: Bool { typeCode & 1 == 1 }
}

public struct TeradataResultSet: Sendable {
    public let columns: [TeradataColumn]
    public let rows: [[TeradataValue]]
    public let activityCount: Int

    public init(columns: [TeradataColumn], rows: [[TeradataValue]], activityCount: Int) {
        self.columns = columns
        self.rows = rows
        self.activityCount = activityCount
    }
}
