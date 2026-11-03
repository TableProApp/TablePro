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
        label: "Use ~/.pgpass",
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

    @Test("Entra ID hides both built-in credentials, since the token replaces them")
    func entraHidesUsernameAndPassword() {
        let fields = mssqlAuthFields()
            + EntraAuthFields.standard(gatedBy: "mssqlAuthMethod", value: "entra")
        #expect(fields.hidesUsername(forValues: ["mssqlAuthMethod": "entra"]) == true)
        #expect(fields.hidesPassword(forValues: ["mssqlAuthMethod": "entra"]) == true)
        #expect(fields.hidesUsername(forValues: ["mssqlAuthMethod": "sql"]) == false)
        #expect(fields.hidesPassword(forValues: ["mssqlAuthMethod": "sql"]) == false)
    }

    @Test("Fields without the hidesUsername flag never hide the username")
    func plainFieldsDoNotHide() {
        let plain = ConnectionField(id: "region", label: "Region", section: .authentication)
        #expect([plain].hidesUsername(forValues: ["region": "us-east-1"]) == false)
        #expect([ConnectionField]().hidesUsername(forValues: [:]) == false)
    }
}

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
        #expect(hides("DynamoDB", ["awsAuthMethod": "local"]))
        #expect(hides("BigQuery", ["bqAuthMethod": "adc"]))
        #expect(hides("Spanner", ["spAuthMethod": "adc"]))
        #expect(hides("Snowflake", ["snowflakeAuthMethod": "externalBrowser"]))
    }

    private func chainedFields() -> [ConnectionField] {
        [
            ConnectionField(
                id: "mode",
                label: "Mode",
                defaultValue: "local",
                fieldType: .dropdown(options: [.init(value: "local", label: "local"), .init(value: "remote", label: "remote")]),
                section: .authentication
            ),
            ConnectionField(
                id: "tls",
                label: "TLS",
                defaultValue: "automatic",
                fieldType: .dropdown(options: [.init(value: "automatic", label: "automatic"), .init(value: "pinned", label: "pinned")]),
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "mode", values: ["remote"])
            ),
            ConnectionField(
                id: "pin",
                label: "Pin",
                required: true,
                section: .authentication,
                visibleWhen: FieldVisibilityRule(fieldId: "tls", values: ["pinned"])
            ),
        ]
    }

    @Test("A field whose controller is hidden is hidden, whatever value the controller keeps")
    func visibilityFollowsAHiddenController() throws {
        let fields = chainedFields()
        let pin = try #require(fields.first { $0.id == "pin" })

        #expect(fields.isVisible(pin, forValues: ["mode": "remote", "tls": "pinned"]))
        #expect(!fields.isVisible(pin, forValues: ["mode": "local", "tls": "pinned"]))
        #expect(!fields.isVisible(pin, forValues: ["tls": "pinned"]), "The controller's default hides it too")
        #expect(!fields.isVisible(pin, forValues: ["mode": "remote", "tls": "automatic"]))
    }

    @Test("A cycle of visibility rules ends, and a controller the list lacks decides nothing")
    func visibilityStopsOnACycleAndAMissingController() throws {
        let cycle = [
            ConnectionField(id: "a", label: "A", visibleWhen: FieldVisibilityRule(fieldId: "b", values: ["on"])),
            ConnectionField(id: "b", label: "B", visibleWhen: FieldVisibilityRule(fieldId: "a", values: ["on"])),
            ConnectionField(id: "c", label: "C", visibleWhen: FieldVisibilityRule(fieldId: "c", values: ["on"])),
        ]
        let first = try #require(cycle.first)
        let selfControlled = try #require(cycle.last)

        #expect(cycle.isVisible(first, forValues: ["a": "on", "b": "on"]))
        #expect(!cycle.isVisible(first, forValues: ["a": "off", "b": "on"]))
        #expect(cycle.isVisible(selfControlled, forValues: ["c": "on"]))

        let orphan = ConnectionField(id: "d", label: "D", visibleWhen: FieldVisibilityRule(fieldId: "elsewhere", values: ["on"]))
        #expect([orphan].isVisible(orphan, forValues: ["elsewhere": "on"]))
        #expect(![orphan].isVisible(orphan, forValues: [:]))
    }

    @Test("DuckDB's CA and fingerprint fields show only in Remote, under the SSL Mode that uses them")
    func duckdbTLSFieldsFollowRemoteMode() throws {
        let fields = PluginManager.shared.additionalConnectionFields(for: .duckdb)
        let caPath = try #require(fields.first { $0.id == "duckdbCACertificateFilePath" })
        let fingerprint = try #require(fields.first { $0.id == "duckdbCertificateFingerprint" })
        let sslMode = try #require(fields.first { $0.id == "duckdbSSLMode" })

        #expect(!fields.isVisible(sslMode, forValues: ["duckdbMode": "local"]))
        #expect(fields.isVisible(sslMode, forValues: ["duckdbMode": "remote"]))
        #expect(fields.isVisible(caPath, forValues: ["duckdbMode": "remote", "duckdbSSLMode": "verifyIdentity"]))
        #expect(!fields.isVisible(caPath, forValues: ["duckdbMode": "local", "duckdbSSLMode": "verifyIdentity"]))
        #expect(fields.isVisible(fingerprint, forValues: ["duckdbMode": "remote", "duckdbSSLMode": "verifyFingerprint"]))
        #expect(!fields.isVisible(fingerprint, forValues: ["duckdbMode": "local", "duckdbSSLMode": "verifyFingerprint"]))
        #expect(!fields.isVisible(fingerprint, forValues: ["duckdbMode": "remote"]), "Automatic is the default")
    }
}
