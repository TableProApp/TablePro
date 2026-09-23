import Foundation

/// One SQLite extension a connection loads when it opens, in the order the list gives.
///
/// `entryPoint` is nil to let SQLite derive it from the file name: `vec0.dylib` gives
/// `sqlite3_vec_init` and `mod_spatialite.dylib` gives `sqlite3_modspatialite_init`. A file that was
/// renamed, or one exporting several entry points, needs it named.
public struct LoadableExtension: Codable, Hashable, Sendable {
    public let path: String
    public let entryPoint: String?

    public init(path: String, entryPoint: String? = nil) {
        self.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEntryPoint = entryPoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.entryPoint = trimmedEntryPoint.isEmpty ? nil : trimmedEntryPoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            entryPoint: try container.decodeIfPresent(String.self, forKey: .entryPoint)
        )
    }

    /// `~` and `~/` name the current user's home. `NSString.expandingTildeInPath` is not used
    /// because it truncates its result at 1,024 bytes without saying so (measured), which would
    /// hand SQLite a shorter path than the one the person listed.
    public var expandedPath: String {
        if path == "~" { return NSHomeDirectory() }
        guard path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + path.dropFirst()
    }

    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    private enum CodingKeys: String, CodingKey {
        case path, entryPoint
    }
}

/// The wire format of a connection's extension list: a JSON array in one connection field value,
/// so it syncs, exports and imports with the rest of `additionalFields`. An empty list is the
/// empty string, which removes the key instead of storing `[]`.
public enum LoadableExtensionList {
    public static let fieldId = "sqliteExtensions"

    public static func decode(_ value: String?) throws -> [LoadableExtension] {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([LoadableExtension].self, from: Data(value.utf8))
        } catch {
            throw LoadableExtensionError.malformedList
        }
    }

    public static func encode(_ extensions: [LoadableExtension]) -> String {
        guard !extensions.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(extensions), let text = String(bytes: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

public extension ConnectionField {
    static func loadableExtensions(visibleWhen: FieldVisibilityRule? = nil) -> ConnectionField {
        ConnectionField(
            id: LoadableExtensionList.fieldId,
            label: String(localized: "Extensions"),
            section: .advanced,
            visibleWhen: visibleWhen
        )
        .withContent(.loadableExtensions)
    }
}
