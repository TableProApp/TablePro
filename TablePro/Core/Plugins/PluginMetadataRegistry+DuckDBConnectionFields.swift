//
//  PluginMetadataRegistry+DuckDBConnectionFields.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    static var duckdbConnectionFields: [ConnectionField] {
        [
            ConnectionField(
                id: "duckdbMode",
                label: String(localized: "Connection Type"),
                defaultValue: "local",
                fieldType: .dropdown(options: [
                    ConnectionField.DropdownOption(value: "local", label: String(localized: "Local File")),
                    ConnectionField.DropdownOption(value: "remote", label: String(localized: "Remote (Quack, experimental)"))
                ]),
                section: .authentication
            ),
            ConnectionField(
                id: "duckdbFilePath",
                label: String(localized: "Database File"),
                placeholder: "/path/to/database.duckdb",
                required: true,
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["local"])
            ),
            ConnectionField(
                id: "duckdbHost",
                label: String(localized: "Host"),
                placeholder: "localhost",
                required: true,
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
            ),
            ConnectionField(
                id: "duckdbPort",
                label: String(localized: "Port"),
                placeholder: "9494",
                defaultValue: "9494",
                fieldType: .number,
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
            ),
            ConnectionField(
                id: "duckdbToken",
                label: String(localized: "Token"),
                fieldType: .secure,
                section: .authentication,
                hidesPassword: true,
                visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
            ),
            ConnectionField(
                id: "duckdbAlias",
                label: String(localized: "Database Alias"),
                placeholder: "remotedb",
                required: true,
                defaultValue: "remotedb",
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
            ),
            /// Named for what it does to the file rather than to TablePro, to keep it apart from
            /// Safe Mode's own Read-Only level: that one is a policy this app applies to itself
            /// and can be changed while connected, this one is how the file is opened and is
            /// fixed for the life of the connection.
            ConnectionField(
                id: "duckdbReadOnly",
                label: String(localized: "Open the File Read-Only"),
                defaultValue: "false",
                fieldType: .toggle,
                section: .advanced,
                visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["local"])
            ),
            ConnectionField(
                id: "duckdbIdleReleaseMinutes",
                label: String(localized: "Release the File Lock After (minutes, 0 to keep it)"),
                defaultValue: "0",
                fieldType: .stepper(range: ConnectionField.IntRange(0...240)),
                section: .advanced,
                visibleWhen: FieldVisibilityRule(fieldId: "duckdbMode", values: ["local"])
            )
        ]
    }
}
