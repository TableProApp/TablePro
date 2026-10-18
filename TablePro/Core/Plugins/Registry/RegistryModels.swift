import Foundation

internal struct RegistryManifest: Sendable {
    internal static let supportedSchemaVersion = 3

    internal let schemaVersion: Int
    internal let plugins: [RegistryPlugin]
}

extension RegistryManifest: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case plugins
    }

    internal init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Schema \(schemaVersion) is not \(Self.supportedSchemaVersion)"
            )
        }
        plugins = try container.decode([RegistryPlugin].self, forKey: .plugins)
    }
}

internal struct RegistryPlugin: Decodable, Sendable, Identifiable {
    internal let id: String
    internal let name: String
    internal let iconName: String?
    internal let databaseTypeIds: [String]?
    internal let exportFormatIds: [String]?
    internal let releases: [RegistryRelease]
}

internal struct RegistryRelease: Decodable, Sendable, Equatable {
    internal let version: String
    internal let build: Int
    internal let channel: String
    internal let pluginKit: Int
    internal let minimumSystemVersion: String
    internal let url: String
    internal let sha256: String
}

internal extension RegistryPlugin {
    func newestRelease(
        channel: UpdateChannel,
        kits: ClosedRange<Int>,
        systemVersion: OperatingSystemVersion
    ) throws -> RegistryRelease {
        let eligible = releases.filter { release in
            channel.accepts(release.channel) && release.runs(on: systemVersion)
        }
        if let newest = eligible.filter({ kits.contains($0.pluginKit) }).max(by: { $0.build < $1.build }) {
            return newest
        }
        if let oldestNewerKit = eligible.map(\.pluginKit).filter({ $0 > kits.upperBound }).min() {
            throw PluginError.appTooOldForPlugin(oldestPublishedKit: oldestNewerKit, appKit: kits.upperBound)
        }
        throw PluginError.noCompatibleRelease
    }
}

internal extension RegistryRelease {
    func runs(on systemVersion: OperatingSystemVersion) -> Bool {
        let parts = minimumSystemVersion.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard (1...3).contains(parts.count), numbers.count == parts.count else { return false }
        let minimum = numbers + Array(repeating: 0, count: 3 - numbers.count)
        let running = [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion]
        return !running.lexicographicallyPrecedes(minimum)
    }
}
