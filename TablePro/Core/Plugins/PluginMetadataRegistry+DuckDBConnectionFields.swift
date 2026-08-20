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
            )
        ]
    }
}
