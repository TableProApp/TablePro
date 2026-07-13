//
//  SurrealDBConnectionFields.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

func surrealDBPluginConnectionFields() -> [ConnectionField] {
    [
        ConnectionField(
            id: SurrealDBConnectionConfig.authLevelField,
            label: String(localized: "Auth Level"),
            defaultValue: SurrealAuthLevel.root.rawValue,
            fieldType: .dropdown(options: [
                .init(value: "root", label: String(localized: "Root")),
                .init(value: "namespace", label: String(localized: "Namespace")),
                .init(value: "database", label: String(localized: "Database")),
                .init(value: "record", label: String(localized: "Record Access")),
                .init(value: "token", label: String(localized: "Token")),
            ]),
            section: .authentication
        ),
        ConnectionField(
            id: SurrealDBConnectionConfig.tokenField,
            label: String(localized: "Token"),
            placeholder: "JWT",
            fieldType: .secure,
            section: .authentication,
            hidesPassword: true,
            visibleWhen: FieldVisibilityRule(fieldId: SurrealDBConnectionConfig.authLevelField, values: ["token"])
        ),
        ConnectionField(
            id: SurrealDBConnectionConfig.accessField,
            label: String(localized: "Access Method"),
            placeholder: "user",
            section: .authentication,
            visibleWhen: FieldVisibilityRule(fieldId: SurrealDBConnectionConfig.authLevelField, values: ["record"])
        ),
        ConnectionField(
            id: SurrealDBConnectionConfig.databaseField,
            label: String(localized: "Database"),
            placeholder: String(localized: "Optional, pick one after connecting"),
            section: .connection
        ),
        ConnectionField(
            id: SurrealDBConnectionConfig.skipTLSVerifyField,
            label: String(localized: "Skip TLS Verification"),
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced
        ),
    ]
}
