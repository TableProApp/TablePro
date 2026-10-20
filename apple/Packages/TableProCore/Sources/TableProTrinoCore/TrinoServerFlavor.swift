import Foundation

public enum TrinoServerFlavor: String, Sendable, Equatable, CaseIterable {
    case trino = "Trino"
    case presto = "Presto"

    public init(driverVariant: String?) {
        self = driverVariant == TrinoServerFlavor.presto.rawValue ? .presto : .trino
    }

    public var productName: String { rawValue }

    public var protocolHeaders: TrinoProtocolHeaders {
        switch self {
        case .trino: .trino
        case .presto: .presto
        }
    }

    // Presto has no version() (measured on 0.299), so it connects on a statement any user can run.
    public var connectStatement: String {
        switch self {
        case .trino: "SELECT version()"
        case .presto: "SELECT 1"
        }
    }

    public var versionStatement: String {
        switch self {
        case .trino: "SELECT version()"
        case .presto: "SELECT node_version FROM system.runtime.nodes WHERE coordinator = true"
        }
    }

    // Presto has no client capabilities header (PrestoHeaders, 0.299).
    public var clientCapabilities: String? {
        switch self {
        case .trino: "PARAMETRIC_DATETIME"
        case .presto: nil
        }
    }
}
