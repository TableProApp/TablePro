//
//  DriverSettingNotSupportedError.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A connection that sets a field the loaded driver does not know yet.
///
/// A registry plugin updates after the app, at the next launch and only when updating is on, so an
/// app can run with a driver built before one of its settings existed. That driver connects as if the
/// field held its default, and for a security setting the default can be weaker than the user's
/// choice. A tunnel to the type's server fields is refused too: those settings are what secure the
/// forwarded hop, and an older DuckDB driver sends the token over plain HTTP to the loopback forward,
/// which the bastion carries on unencrypted. Only the fields a type's curated entry names are checked:
/// an unknown field elsewhere is just ignored, as it always was.
struct DriverSettingNotSupportedError: Error, LocalizedError, Equatable {
    enum Setting: Equatable {
        case field(label: String)
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
        let declared = Set(pluginType.additionalConnectionFields.map(\.id))
        guard required.contains(where: { !declared.contains($0) }) else { return nil }
        let typeName = connection.type.displayName
        let tunneled = !connection.enabledTunnelKinds.isEmpty || connection.preTunnelHost != nil
        if connection.activeServerEndpointFields != nil, tunneled {
            return DriverSettingNotSupportedError(setting: .tunnel, typeName: typeName)
        }
        let curatedFields = curated.connection.additionalConnectionFields
        for fieldId in required where !declared.contains(fieldId) {
            guard let field = curatedFields.first(where: { $0.id == fieldId }),
                  curatedFields.isVisible(field, forValues: connection.additionalFields)
            else { continue }
            let value = (connection.additionalFields[fieldId] ?? "").trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != (field.defaultValue ?? "") else { continue }
            return DriverSettingNotSupportedError(setting: .field(label: field.label), typeName: typeName)
        }
        return nil
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
