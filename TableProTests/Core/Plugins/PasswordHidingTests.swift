//
//  PasswordHidingTests.swift
//  TableProTests
//
//  The single source of truth for "does this connection's auth mode replace the
//  password" feeds both the connection form (whether to show the prompt toggle)
//  and the runtime connect/reconnect paths (whether to prompt at all).
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Password hiding from connection fields")
struct PasswordHidingTests {
    private func dropdown(default defaultValue: String, _ values: [String]) -> ConnectionField {
        ConnectionField(
            id: "awsAuth",
            label: "Authentication",
            defaultValue: defaultValue,
            fieldType: .dropdown(options: values.map { .init(value: $0, label: $0) }),
            section: .authentication,
            hidesPassword: true
        )
    }

    private let pgpassToggle = ConnectionField(
        id: "usePgpass",
        label: "Use Password File",
        defaultValue: "false",
        fieldType: .toggle,
        section: .authentication,
        hidesPassword: true
    )

    private let secretField = ConnectionField(
        id: "serviceAccountJson",
        label: "Service Account",
        fieldType: .secure,
        section: .authentication,
        hidesPassword: true
    )

    private func gatedSecretFields() -> [ConnectionField] {
        [
            ConnectionField(
                id: "authMode",
                label: "Auth",
                defaultValue: "password",
                fieldType: .dropdown(options: [
                    .init(value: "password", label: "password"),
                    .init(value: "token", label: "token"),
                ]),
                section: .authentication
            ),
            ConnectionField(
                id: "token",
                label: "Token",
                fieldType: .secure,
                section: .authentication,
                hidesPassword: true,
                visibleWhen: FieldVisibilityRule(fieldId: "authMode", values: ["token"])
            ),
        ]
    }

    @Test("A dropdown hides the password only when set off its default")
    func dropdownAwayFromDefault() {
        let fields = [dropdown(default: "off", ["off", "accessKey", "profile"])]
        #expect(fields.hidesPassword(forValues: [:]) == false)
        #expect(fields.hidesPassword(forValues: ["awsAuth": "off"]) == false)
        #expect(fields.hidesPassword(forValues: ["awsAuth": "accessKey"]) == true)
        #expect(fields.hidesPassword(forValues: ["awsAuth": "profile"]) == true)
    }

    @Test("A toggle hides the password only when on")
    func toggleOn() {
        let fields = [pgpassToggle]
        #expect(fields.hidesPassword(forValues: [:]) == false)
        #expect(fields.hidesPassword(forValues: ["usePgpass": "false"]) == false)
        #expect(fields.hidesPassword(forValues: ["usePgpass": "true"]) == true)
    }

    @Test("A secure field with no visibility rule always hides the password")
    func secureFieldAlwaysHides() {
        #expect([secretField].hidesPassword(forValues: [:]) == true)
    }

    @Test("A secure field hidden by its visibility rule does not hide the password")
    func hiddenSecureFieldDoesNotHide() {
        let fields = gatedSecretFields()
        #expect(fields.hidesPassword(forValues: [:]) == false)
        #expect(fields.hidesPassword(forValues: ["authMode": "password"]) == false)
        #expect(fields.hidesPassword(forValues: ["authMode": "token"]) == true)
    }

    @Test("Fields without the hidesPassword flag never hide the password")
    func plainFieldsDoNotHide() {
        let plain = ConnectionField(id: "region", label: "Region", section: .authentication)
        #expect([plain].hidesPassword(forValues: ["region": "us-east-1"]) == false)
        #expect([ConnectionField]().hidesPassword(forValues: [:]) == false)
    }

    @Test("Only authentication-section fields are considered")
    func ignoresNonAuthenticationFields() {
        let advanced = ConnectionField(
            id: "advancedToggle",
            label: "Advanced",
            defaultValue: "false",
            fieldType: .toggle,
            section: .advanced,
            hidesPassword: true
        )
        #expect([advanced].hidesPassword(forValues: ["advancedToggle": "true"]) == false)
    }
}

@Suite("Username hiding from connection fields")
struct UsernameHidingTests {
    private func mssqlAuthFields() -> [ConnectionField] {
        [
            ConnectionField(
                id: "mssqlAuthMethod",
                label: "Authentication",
                defaultValue: "sql",
                fieldType: .dropdown(options: [
                    .init(value: "sql", label: "SQL Server Authentication"),
                    .init(value: "windows", label: "Windows Authentication (Kerberos)"),
                ]),
                section: .authentication
            ),
            ConnectionField(
                id: "mssqlKerberosPrincipal",
                label: "Kerberos Principal",
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "mssqlAuthMethod", values: ["windows"])
            ).withHidesUsername(true),
        ]
    }

    @Test("Windows auth hides the built-in username, SQL auth does not")
    func windowsHidesUsername() {
        let fields = mssqlAuthFields()
        #expect(fields.hidesUsername(forValues: [:]) == false)
        #expect(fields.hidesUsername(forValues: ["mssqlAuthMethod": "sql"]) == false)
        #expect(fields.hidesUsername(forValues: ["mssqlAuthMethod": "windows"]) == true)
    }

    @Test("hidesUsername is independent of hidesPassword")
    func usernameHidingIsIndependent() {
        let fields = mssqlAuthFields()
        #expect(fields.hidesPassword(forValues: ["mssqlAuthMethod": "windows"]) == false)
    }

    @Test("Fields without the hidesUsername flag never hide the username")
    func plainFieldsDoNotHide() {
        let plain = ConnectionField(id: "region", label: "Region", section: .authentication)
        #expect([plain].hidesUsername(forValues: ["region": "us-east-1"]) == false)
        #expect([ConnectionField]().hidesUsername(forValues: [:]) == false)
    }
}

@Suite("Password hiding resolved from plugin metadata")
@MainActor
struct PluginManagerPasswordHidingTests {
    private func connection(type: DatabaseType, fields: [String: String]) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "test", type: type)
        connection.additionalFields = fields
        return connection
    }

    private func hides(_ typeId: String, _ fields: [String: String]) -> Bool {
        PluginManager.shared.hidesPassword(for: connection(type: DatabaseType(rawValue: typeId), fields: fields))
    }

    @Test("AWS IAM modes hide the password for relational types")
    func iamHidesPassword() {
        let manager = PluginManager.shared
        #expect(manager.hidesPassword(for: connection(type: .mysql, fields: ["awsAuth": "accessKey"])))
        #expect(manager.hidesPassword(for: connection(type: .postgresql, fields: ["awsAuth": "profile"])))
    }

    @Test("Password auth does not hide the password")
    func passwordModeDoesNotHide() {
        let manager = PluginManager.shared
        #expect(!manager.hidesPassword(for: connection(type: .mysql, fields: ["awsAuth": "off"])))
        #expect(!manager.hidesPassword(for: connection(type: .mysql, fields: [:])))
    }

    @Test("Plugins that never use the built-in password hide it in every mode")
    func cloudPluginsHideBuiltInPassword() {
        #expect(hides("DuckDB", ["duckdbMode": "local"]))
        #expect(hides("DuckDB", ["duckdbMode": "remote"]))
        #expect(hides("DynamoDB", ["awsAuthMethod": "profile"]))
        #expect(hides("BigQuery", ["bqAuthMethod": "adc"]))
        #expect(hides("Snowflake", ["snowflakeAuthMethod": "externalBrowser"]))
    }
}
