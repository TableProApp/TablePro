import Foundation

public enum FirebaseFieldID {
    public static let authMethod = "fbAuthMethod"
    public static let serviceAccountJson = "fbServiceAccountJson"
    public static let projectId = "fbProjectId"
    public static let firestoreDatabase = "fbDatabaseId"
    public static let databaseURL = "fbDatabaseURL"
    public static let emulatorHost = "fbEmulatorHost"
    public static let driverVariant = "driverVariant"
}

public enum FirebaseVariant: String, Sendable {
    case firestore
    case realtimeDatabase
}

public enum FirebaseAuthMethod: String, Sendable, CaseIterable {
    case serviceAccount
    case applicationDefault = "adc"
    case emulator
}

public struct FirebaseConnectionSettings: Sendable, Equatable {
    public static let defaultFirestoreDatabase = "(default)"
    public static let firestoreEndpoint = URL(string: "https://firestore.googleapis.com/v1/")

    public let variant: FirebaseVariant
    public let authMethod: FirebaseAuthMethod
    public let projectId: String?
    public let firestoreDatabase: String
    public let databaseURL: URL?
    public let emulatorHost: String?

    public init(
        variant: FirebaseVariant,
        authMethod: FirebaseAuthMethod,
        projectId: String?,
        firestoreDatabase: String = FirebaseConnectionSettings.defaultFirestoreDatabase,
        databaseURL: URL? = nil,
        emulatorHost: String? = nil
    ) {
        self.variant = variant
        self.authMethod = authMethod
        self.projectId = projectId
        self.firestoreDatabase = firestoreDatabase
        self.databaseURL = databaseURL
        self.emulatorHost = emulatorHost
    }

    /// `credentialProject` stands in for an empty Project ID, so a key alone is enough to connect.
    public static func parse(fields: [String: String], credentialProject: String? = nil) throws -> FirebaseConnectionSettings {
        let variant: FirebaseVariant = fields[FirebaseFieldID.driverVariant] == FirebaseVariant.realtimeDatabase.rawValue
            ? .realtimeDatabase : .firestore
        let authMethod = trimmed(fields[FirebaseFieldID.authMethod]).flatMap(FirebaseAuthMethod.init(rawValue:))
            ?? .serviceAccount
        let emulatorHost = authMethod == .emulator ? try parseEmulatorHost(fields[FirebaseFieldID.emulatorHost]) : nil
        let projectId = trimmed(fields[FirebaseFieldID.projectId]) ?? credentialProject
        if let projectId, !isValidProjectId(projectId) {
            throw FirebaseError.configuration(
                String(format: String(localized: "\"%@\" is not a Google Cloud project ID."), projectId)
            )
        }
        let databaseURL = try trimmed(fields[FirebaseFieldID.databaseURL]).map { try parseDatabaseURL($0, emulator: authMethod == .emulator) }

        switch variant {
        case .firestore where projectId == nil:
            throw FirebaseError.configuration(String(localized: "Enter a Project ID, or use a service account key that names one."))
        case .realtimeDatabase where projectId == nil && databaseURL == nil:
            throw FirebaseError.configuration(String(localized: "Enter a Database URL or a Project ID."))
        default:
            break
        }
        return FirebaseConnectionSettings(
            variant: variant,
            authMethod: authMethod,
            projectId: projectId,
            firestoreDatabase: trimmed(fields[FirebaseFieldID.firestoreDatabase]) ?? defaultFirestoreDatabase,
            databaseURL: databaseURL,
            emulatorHost: emulatorHost
        )
    }

    public var firestoreBaseURL: URL? {
        if let emulatorHost {
            return URL(string: "http://\(emulatorHost)/v1/")
        }
        return Self.firestoreEndpoint
    }

    /// The fallback when the management API names no instance. The emulator, like the SDKs, calls
    /// a project's default database `<project>-default-rtdb`.
    public var defaultDatabaseURL: URL? {
        if let databaseURL { return databaseURL }
        guard let projectId else { return nil }
        if let emulatorHost {
            return URL(string: "http://\(emulatorHost)/?ns=\(projectId)-default-rtdb")
        }
        return URL(string: "https://\(projectId)-default-rtdb.firebaseio.com/")
    }

    static func isValidProjectId(_ text: String) -> Bool {
        text.range(of: #"^(?:[a-z][a-z0-9.:-]{2,62})$"#, options: .regularExpression) != nil
    }

    /// The token goes to this host, so outside the emulator it must be one of Firebase's own.
    static func parseDatabaseURL(_ text: String, emulator: Bool) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            throw invalidURL(text)
        }
        if emulator {
            guard scheme == "http" || scheme == "https" else { throw invalidURL(text) }
            return url
        }
        let trusted = host.hasSuffix(".firebaseio.com") || host.hasSuffix(".firebasedatabase.app")
        guard scheme == "https", trusted else { throw invalidURL(text) }
        return URL(string: "https://\(host)/") ?? url
    }

    static func parseEmulatorHost(_ text: String?) throws -> String {
        let value = trimmed(text)?
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        guard value.range(of: #"^[A-Za-z0-9.\-\[\]:]+:\d{1,5}$"#, options: .regularExpression) != nil else {
            throw FirebaseError.configuration(String(localized: "Enter the emulator as host:port, such as 127.0.0.1:8080."))
        }
        return value
    }

    private static func invalidURL(_ text: String) -> FirebaseError {
        .configuration(String(
            format: String(localized: "\"%@\" is not a Realtime Database URL. It looks like https://<name>.firebaseio.com or https://<name>.<region>.firebasedatabase.app."),
            text
        ))
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
