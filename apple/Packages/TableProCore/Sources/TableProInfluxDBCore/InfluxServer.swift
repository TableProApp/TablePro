import Foundation

public enum InfluxGeneration: Sendable, Equatable {
    case v1
    case v2
    case v3

    /// Reads the `X-Influxdb-Version` header `/ping` returns: `v2.9.1` on 2.x, `3.12.2` on 3.x,
    /// `1.11.8` on 1.x. A server that sends none is taken as 3.x, the only line whose `/ping`
    /// body also names the version.
    public init(versionHeader: String?) {
        let trimmed = (versionHeader ?? "").trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        switch digits.split(separator: ".").first.flatMap({ Int($0) }) {
        case 1: self = .v1
        case 2: self = .v2
        default: self = .v3
        }
    }

    public var languages: [InfluxQueryLanguage] {
        switch self {
        case .v1: return [.influxQL]
        case .v2: return [.flux, .influxQL]
        case .v3: return [.sql, .influxQL]
        }
    }

    /// The language the data grid's queries are written in: both read the same
    /// `SELECT ... FROM "m" ORDER BY time DESC LIMIT n OFFSET m`.
    public var gridLanguage: InfluxQueryLanguage {
        self == .v3 ? .sql : .influxQL
    }
}

public struct InfluxServerInfo: Sendable, Equatable {
    public let generation: InfluxGeneration
    public let version: String

    public init(generation: InfluxGeneration, version: String) {
        self.generation = generation
        self.version = version
    }

    public init(versionHeader: String?) {
        let version = (versionHeader ?? "").trimmingCharacters(in: .whitespaces)
        self.init(generation: InfluxGeneration(versionHeader: versionHeader), version: version)
    }
}
