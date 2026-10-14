import Foundation

public enum BigtableFieldID {
    public static let authMethod = "btAuthMethod"
    public static let serviceAccountJson = "btServiceAccountJson"
    public static let projectId = "btProjectId"
    public static let instanceId = "btInstanceId"
    public static let appProfileId = "btAppProfileId"
}

public enum BigtableAuthMethod: String, Sendable, CaseIterable {
    case serviceAccount
    case applicationDefault = "adc"
}

public struct BigtableConnectionSettings: Sendable, Equatable {
    public let authMethod: BigtableAuthMethod
    public let projectId: String
    public let instanceId: String?
    public let appProfileId: String?

    public init(authMethod: BigtableAuthMethod, projectId: String, instanceId: String?, appProfileId: String? = nil) {
        self.authMethod = authMethod
        self.projectId = projectId
        self.instanceId = instanceId
        self.appProfileId = appProfileId
    }

    /// `credentialProject` is the project the key or Application Default Credentials name, used
    /// when the Project ID field is empty. With no Instance ID the driver opens the project's only
    /// instance, or the first one, and lists the rest in the database switcher.
    public static func parse(fields: [String: String], credentialProject: String? = nil) throws -> BigtableConnectionSettings {
        let authMethod = trimmed(fields[BigtableFieldID.authMethod]).flatMap(BigtableAuthMethod.init(rawValue:)) ?? .serviceAccount
        guard let projectId = trimmed(fields[BigtableFieldID.projectId]) ?? credentialProject else {
            throw BigtableError.configuration(String(localized: "Enter a Project ID, or use a service account key that names one."))
        }
        guard isValidProjectId(projectId) else {
            throw BigtableError.configuration(String(format: String(localized: "\"%@\" is not a Google Cloud project ID."), projectId))
        }
        let instanceId = trimmed(fields[BigtableFieldID.instanceId])
        if let instanceId, !isValidResourceId(instanceId) {
            throw BigtableError.configuration(String(format: String(localized: "\"%@\" is not a Bigtable instance ID."), instanceId))
        }
        let appProfileId = trimmed(fields[BigtableFieldID.appProfileId])
        if let appProfileId, !isValidResourceId(appProfileId) {
            throw BigtableError.configuration(String(format: String(localized: "\"%@\" is not an app profile ID."), appProfileId))
        }
        return BigtableConnectionSettings(authMethod: authMethod, projectId: projectId, instanceId: instanceId, appProfileId: appProfileId)
    }

    static func isValidProjectId(_ text: String) -> Bool {
        text.range(of: #"^[a-z][a-z0-9.:-]{2,62}$"#, options: .regularExpression) != nil
    }

    /// Instance, table and app profile IDs all go into the request path, so anything outside the
    /// characters Bigtable allows is refused before it can change the path.
    static func isValidResourceId(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,49}$"#, options: .regularExpression) != nil
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
