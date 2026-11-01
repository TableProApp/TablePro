import Foundation

public enum InfluxGeneration: Sendable, Equatable {
    case v2
    case v3

    public init?(version: String) {
        switch Self.major(of: version) {
        case 2: self = .v2
        case let major? where major >= 3: self = .v3
        default: return nil
        }
    }

    // `v2.9.1` on 2.x, `3.12.2` on 3.x, `1.11.8` on 1.x.
    static func major(of version: String) -> Int? {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("v") ? trimmed.dropFirst() : Substring(trimmed)
        return digits.split(separator: ".").first.flatMap { Int($0) }
    }

    public var languages: [InfluxQueryLanguage] {
        switch self {
        case .v2: return [.flux, .influxQL]
        case .v3: return [.sql, .influxQL]
        }
    }

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

    // A proxy may drop the `X-Influxdb-Version` header; 3.x also names its version in the `/ping` body.
    public init(versionHeader: String?, pingBody: Data) throws {
        let candidates = [versionHeader, Self.bodyVersion(pingBody)].compactMap { $0 }
        for candidate in candidates {
            let version = candidate.trimmingCharacters(in: .whitespaces)
            if let generation = InfluxGeneration(version: version) {
                self.init(generation: generation, version: version)
                return
            }
            if InfluxGeneration.major(of: version) != nil {
                throw InfluxError.unsupportedVersion(version)
            }
        }
        throw InfluxError.unknownVersion
    }

    private static func bodyVersion(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }
}
