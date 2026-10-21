import Foundation

/// A database file a connection attaches beside the one it opens, so a statement reaches its tables as
/// `name.table`. An attachment lasts only as long as the handle, so a driver attaches the whole list
/// again on every connect.
public struct AttachedDatabase: Codable, Hashable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            path: try container.decode(String.self, forKey: .path)
        )
    }

    // `NSString.expandingTildeInPath` truncates its result at 1,024 bytes without saying so.
    public var expandedPath: String {
        if path == "~" { return NSHomeDirectory() }
        guard path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + path.dropFirst()
    }

    /// The file name without its extension, which is the name a file is offered under: `auth.db`
    /// attaches as `auth`.
    public static func defaultName(forPath path: String) -> String {
        let fileName = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? fileName : stem
    }

    private enum CodingKeys: String, CodingKey {
        case name, path
    }
}

/// The wire format of a connection's attached databases: a JSON array in one connection field value,
/// so it syncs, exports and imports with the rest of `additionalFields`. An empty list is the empty
/// string, which removes the key instead of storing `[]`.
public enum AttachedDatabaseList {
    public static let fieldId = "attachedDatabases"

    /// The names SQLite and DuckDB keep for the opened file and for temporary objects. SQLite compares
    /// database names without regard to case.
    public static let reservedNames: Set<String> = ["main", "temp"]

    public static func decode(_ value: String?) throws -> [AttachedDatabase] {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([AttachedDatabase].self, from: Data(value.utf8))
        } catch {
            throw AttachedDatabaseError.malformedList
        }
    }

    public static func encode(_ databases: [AttachedDatabase]) -> String {
        guard !databases.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(databases), let text = String(bytes: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    /// `auth` for `auth.db`, then `auth_2`, `auth_3` while a name is reserved or already in the list.
    public static func uniqueName(forPath path: String, taken: some Sequence<String>) -> String {
        let used = Set(taken.map { $0.lowercased() }).union(reservedNames)
        let base = AttachedDatabase.defaultName(forPath: path)
        guard used.contains(base.lowercased()) else { return base }
        var counter = 2
        while used.contains("\(base)_\(counter)".lowercased()) {
            counter += 1
        }
        return "\(base)_\(counter)"
    }

    /// The first problem that would stop an attachment, in list order. A list that passes can still fail
    /// at connect, for a file that is gone or is not a database.
    public static func validate(_ databases: [AttachedDatabase]) throws {
        var seen = Set<String>()
        for database in databases {
            guard !database.path.isEmpty else { throw AttachedDatabaseError.missingPath(database) }
            guard database.expandedPath.hasPrefix("/") else { throw AttachedDatabaseError.relativePath(database) }
            guard !database.name.isEmpty else { throw AttachedDatabaseError.missingName(database) }
            let key = database.name.lowercased()
            guard !reservedNames.contains(key) else { throw AttachedDatabaseError.reservedName(database) }
            guard seen.insert(key).inserted else { throw AttachedDatabaseError.duplicateName(database) }
        }
    }
}

public enum AttachedDatabaseError: Error, Equatable, Sendable {
    case malformedList
    case missingPath(AttachedDatabase)
    case relativePath(AttachedDatabase)
    case missingName(AttachedDatabase)
    case reservedName(AttachedDatabase)
    case duplicateName(AttachedDatabase)
    case remoteSession
}

extension AttachedDatabaseError: LocalizedError {
    public var errorDescription: String? {
        failureReason
    }

    public var failureReason: String? {
        switch self {
        case .malformedList:
            return String(localized: "The saved list of attached databases is not in a format TablePro can read.")
        case .missingPath(let database):
            return String(format: String(localized: "The attached database \"%@\" has no file."), database.name)
        case .relativePath(let database):
            return String(format: String(localized: "\"%@\" is not a full path."), database.path)
        case .missingName(let database):
            return String(format: String(localized: "The attached file \"%@\" has no name."), database.path)
        case .reservedName(let database):
            return String(
                format: String(localized: "\"%@\" is a name the database keeps for itself. Choose another name."),
                database.name
            )
        case .duplicateName(let database):
            return String(format: String(localized: "More than one attached database is named \"%@\"."), database.name)
        case .remoteSession:
            return String(localized: "Attached databases open only for a database file on this Mac, not for a database on a server.")
        }
    }
}

/// An attachment a connect skipped, and why. The connection opens without it, so the reason goes to
/// the user as the connection's warning rather than as a failed connect.
public struct AttachedDatabaseFailure: Equatable, Sendable {
    public let database: AttachedDatabase
    public let reason: String

    public init(database: AttachedDatabase, reason: String) {
        self.database = database
        self.reason = reason
    }
}

public enum AttachedDatabaseAttacher {
    /// Attaches each database in order and answers the ones that did not attach. A file that is not
    /// there is never handed to the engine: SQLite and DuckDB both create a new, empty database at a
    /// path they do not find, which would read as an attachment with no tables.
    public static func attach(
        _ databases: [AttachedDatabase],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        attach: (AttachedDatabase) async throws -> Void
    ) async -> [AttachedDatabaseFailure] {
        var failures: [AttachedDatabaseFailure] = []
        for database in databases {
            guard fileExists(database.expandedPath) else {
                failures.append(AttachedDatabaseFailure(
                    database: database,
                    reason: String(format: String(localized: "There is no file at \"%@\"."), database.path)
                ))
                continue
            }
            do {
                try await attach(database)
            } catch {
                failures.append(AttachedDatabaseFailure(database: database, reason: error.localizedDescription))
            }
        }
        return failures
    }

    public static func warning(for failures: [AttachedDatabaseFailure]) -> String? {
        guard !failures.isEmpty else { return nil }
        return failures
            .map {
                String(
                    format: String(localized: "Could not attach \"%@\": %@"),
                    $0.database.name,
                    $0.reason
                )
            }
            .joined(separator: "\n")
    }
}

public extension ConnectionField {
    static func attachedDatabases(visibleWhen: FieldVisibilityRule? = nil) -> ConnectionField {
        ConnectionField(
            id: AttachedDatabaseList.fieldId,
            label: String(localized: "Attached Databases"),
            section: .advanced,
            visibleWhen: visibleWhen
        )
        .withContent(.attachedDatabases)
    }
}
