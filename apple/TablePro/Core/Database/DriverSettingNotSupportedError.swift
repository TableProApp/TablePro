//
//  DriverSettingNotSupportedError.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// A registry plugin can be older than the app, and it reads a field or option it does not know as the default, which
// can be weaker than the user's choice. Only the fields a type's curated entry names are checked.
struct DriverSettingNotSupportedError: Error, LocalizedError, Equatable {
    enum Setting: Equatable {
        case field(label: String)
        case option(label: String, option: String)
        case tunnel
    }

    let setting: Setting
    let typeName: String

    static func refusal(
        for connection: DatabaseConnection,
        pluginType: any DriverPlugin.Type
    ) -> DriverSettingNotSupportedError? {
        guard let curated = PluginMetadataRegistry.shared.curatedSnapshot(for: connection.type) else { return nil }
        let required = curated.capabilities.fieldsRequiringDriverSupport
        guard !required.isEmpty else { return nil }
        let typeName = connection.type.displayName
        let curatedFields = curated.connection.additionalConnectionFields
        let pluginFields = pluginType.additionalConnectionFields
        if let setting = unofferedOption(in: connection, required: required, curatedFields: curatedFields, pluginFields: pluginFields) {
            return DriverSettingNotSupportedError(setting: setting, typeName: typeName)
        }
        let declared = Set(pluginFields.map(\.id))
        guard required.contains(where: { !declared.contains($0) }) else { return nil }
        // The missing fields secure the forwarded hop: an older DuckDB driver sends its token in plain HTTP to the loopback.
        let tunneled = !connection.enabledTunnelKinds.isEmpty || connection.preTunnelHost != nil
        if connection.activeServerEndpointFields != nil, tunneled {
            return DriverSettingNotSupportedError(setting: .tunnel, typeName: typeName)
        }
        for fieldId in required where !declared.contains(fieldId) {
            guard let field = curatedFields.first(where: { $0.id == fieldId }),
                  chosenValue(of: field, in: connection, among: curatedFields) != nil
            else { continue }
            return DriverSettingNotSupportedError(setting: .field(label: field.label), typeName: typeName)
        }
        return nil
    }

    // A driver that declares the dropdown but not the chosen option opens another one: an older DuckDB driver opens a
    // MotherDuck row as a local file.
    private static func unofferedOption(
        in connection: DatabaseConnection,
        required: [String],
        curatedFields: [ConnectionField],
        pluginFields: [ConnectionField]
    ) -> Setting? {
        for fieldId in required {
            guard let field = curatedFields.first(where: { $0.id == fieldId }),
                  case .dropdown(let curatedOptions) = field.fieldType,
                  case .dropdown(let offered)? = pluginFields.first(where: { $0.id == fieldId })?.fieldType,
                  let value = chosenValue(of: field, in: connection, among: curatedFields),
                  !offered.contains(where: { $0.value == value })
            else { continue }
            let option = curatedOptions.first { $0.value == value }?.label ?? value
            return .option(label: field.label, option: option)
        }
        return nil
    }

    private static func chosenValue(
        of field: ConnectionField,
        in connection: DatabaseConnection,
        among fields: [ConnectionField]
    ) -> String? {
        guard fields.isVisible(field, forValues: connection.additionalFields) else { return nil }
        let value = (connection.additionalFields[field.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != (field.defaultValue ?? "") else { return nil }
        return value
    }

    var errorDescription: String? {
        switch setting {
        case .field(let label):
            return String(
                format: String(
                    localized: """
                        This connection sets %1$@, which the installed %2$@ driver does not support yet. \
                        Update the database driver in Settings > Extensions, then connect again.
                        """
                ),
                label,
                typeName
            )
        case .option(let label, let option):
            return String(
                format: String(
                    localized: """
                        This connection sets %1$@ to %2$@, which the installed %3$@ driver does not support yet. \
                        Update the database driver in Settings > Extensions, then connect again.
                        """
                ),
                label,
                option,
                typeName
            )
        case .tunnel:
            return String(
                format: String(
                    localized: """
                        The installed %@ driver cannot connect through a tunnel yet. Update the database driver \
                        in Settings > Extensions, then connect again.
                        """
                ),
                typeName
            )
        }
    }
}

extension DriverSettingNotSupportedError: ConnectionPreflightReporting {
    var failedBeforeDialing: Bool { true }
}
