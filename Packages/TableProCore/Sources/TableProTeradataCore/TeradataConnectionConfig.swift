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

public struct TeradataConnectionConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var password: String
    public var database: String?
    public var account: String?
    public var logMech: TeradataLogMech
    public var transactionMode: TeradataTransactionMode
    public var connectTimeoutSeconds: Int

    public init(
        host: String,
        port: UInt16 = 1025,
        username: String,
        password: String,
        database: String? = nil,
        account: String? = nil,
        logMech: TeradataLogMech = .td2,
        transactionMode: TeradataTransactionMode = .default,
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
        self.connectTimeoutSeconds = connectTimeoutSeconds
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
