//
//  AuthFieldOrderTests.swift
//  TableProTests
//
//  The connection form renders credential controllers above the built-in Username and
//  Password so the selector does not shift position when its own selection hides them.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Auth field ordering")
struct AuthFieldOrderTests {
    private func selector(_ id: String, hidesPassword: Bool = false) -> ConnectionField {
        ConnectionField(
            id: id,
            label: "Authentication",
            defaultValue: "off",
            fieldType: .dropdown(options: [.init(value: "off", label: "Off"), .init(value: "on", label: "On")]),
            section: .authentication,
            hidesPassword: hidesPassword
        )
    }

    private func dependent(
        _ id: String,
        of controllerId: String,
        hidesPassword: Bool = false,
        hidesUsername: Bool = false
    ) -> ConnectionField {
        ConnectionField(
            id: id,
            label: id,
            section: .authentication,
            hidesPassword: hidesPassword,
            visibleWhen: FieldVisibilityRule(fieldId: controllerId, values: ["on"])
        ).withHidesUsername(hidesUsername)
    }

    @Test("A selector whose dependent field hides the password is pulled above the credentials")
    func controllerOfDependentIsSplitOut() {
        let fields = [
            selector("mssqlAuthMethod"),
            dependent("kerberosPrincipal", of: "mssqlAuthMethod", hidesUsername: true),
            dependent("kerberosPassword", of: "mssqlAuthMethod", hidesPassword: true),
            ConnectionField(id: "mssqlSchema", label: "Schema", section: .authentication)
        ]

        let split = fields.splitCredentialControllers()

        #expect(split.controllers.map(\.id) == ["mssqlAuthMethod"])
        #expect(split.rest.map(\.id) == ["kerberosPrincipal", "kerberosPassword", "mssqlSchema"])
    }

    @Test("A selector that hides the password itself is pulled above the credentials too")
    func selfHidingControllerIsSplitOut() {
        let fields = [
            selector("esAuthMethod", hidesPassword: true),
            ConnectionField(id: "esApiKey", label: "API Key", section: .authentication)
        ]

        let split = fields.splitCredentialControllers()

        #expect(split.controllers.map(\.id) == ["esAuthMethod"])
        #expect(split.rest.map(\.id) == ["esApiKey"])
    }

    @Test("Fields that touch neither credential keep their original order below them")
    func nonControllersKeepOrder() {
        let fields = [
            ConnectionField(id: "warehouse", label: "Warehouse", section: .authentication),
            ConnectionField(id: "role", label: "Role", section: .authentication)
        ]

        let split = fields.splitCredentialControllers()

        #expect(split.controllers.isEmpty)
        #expect(split.rest.map(\.id) == ["warehouse", "role"])
    }

    @Test("Several controllers keep their relative order")
    func multipleControllersKeepRelativeOrder() {
        let fields = [
            ConnectionField(
                id: "usePgpass",
                label: "Use ~/.pgpass",
                defaultValue: "false",
                fieldType: .toggle,
                section: .authentication,
                hidesPassword: true
            ),
            selector("awsAuth", hidesPassword: true),
            dependent("awsRegion", of: "awsAuth")
        ]

        let split = fields.splitCredentialControllers()

        #expect(split.controllers.map(\.id) == ["usePgpass", "awsAuth"])
        #expect(split.rest.map(\.id) == ["awsRegion"])
    }

    @Test("A controller declared after its dependent is still pulled above the credentials")
    func controllerDeclaredAfterDependentIsFound() {
        let fields = [
            dependent("token", of: "authLevel", hidesPassword: true),
            selector("authLevel")
        ]

        let split = fields.splitCredentialControllers()

        #expect(split.controllers.map(\.id) == ["authLevel"])
        #expect(split.rest.map(\.id) == ["token"])
    }
}
