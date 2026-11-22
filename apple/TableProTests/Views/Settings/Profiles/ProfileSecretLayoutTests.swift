//
//  ProfileSecretLayoutTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro
import TableProPluginKit

// A credential profile has no database type, so its sheet shows one type's secrets at a time and keeps the ones a
// sign-in method needs under that method instead of listing AWS, Google Cloud and Kerberos keys for every engine.
struct ProfileSecretLayoutTests {
    private static let methodPicker = ConnectionField(
        id: "signIn",
        label: "Authentication",
        defaultValue: "off",
        fieldType: .dropdown(options: [
            .init(value: "off", label: "Password"),
            .init(value: "accessKey", label: "Access Key"),
            .init(value: "kerberos", label: "Kerberos"),
        ]),
        section: .authentication
    )

    private static func secret(_ id: String, when values: [String]? = nil, controller: String = "signIn") -> ConnectionField {
        ConnectionField(
            id: id,
            label: id,
            secure: true,
            section: .authentication,
            visibleWhen: values.map { FieldVisibilityRule(fieldId: controller, values: $0) }
        )
    }

    private static let fields = [
        methodPicker,
        secret("apiKey"),
        secret("secretAccessKey", when: ["accessKey"]),
        secret("sessionToken", when: ["accessKey"]),
        secret("kerberosPassword", when: ["kerberos"]),
    ]

    @Test("The default sign-in method shows only the secrets every method needs")
    func defaultMethodHidesMethodSecrets() {
        let layout = ProfileSecretLayout(fields: Self.fields)
        let method = layout.initialMethod(holding: [])

        #expect(layout.methodField?.id == "signIn")
        #expect(method == "off")
        #expect(layout.fields(for: method).map { $0.id } == ["apiKey"])
    }

    @Test("Picking a method adds that method's secrets and no other")
    func methodShowsItsOwnSecrets() {
        let layout = ProfileSecretLayout(fields: Self.fields)

        #expect(layout.fields(for: "accessKey").map { $0.id } == ["apiKey", "secretAccessKey", "sessionToken"])
        #expect(layout.fields(for: "kerberos").map { $0.id } == ["apiKey", "kerberosPassword"])
        #expect(layout.methods.map { $0.value } == ["off", "accessKey", "kerberos"])
    }

    @Test("A profile holding a method's secret opens on that method")
    func heldSecretPicksItsMethod() {
        let layout = ProfileSecretLayout(fields: Self.fields)
        #expect(layout.initialMethod(holding: ["kerberosPassword"]) == "kerberos")
    }

    @Test("Secrets gated by something other than a menu are listed directly")
    func nonMenuGateListsEverything() {
        let toggle = ConnectionField(id: "useToken", label: "Use Token", fieldType: .toggle)
        let layout = ProfileSecretLayout(fields: [toggle, Self.secret("token", when: ["true"], controller: "useToken")])

        #expect(layout.methodField == nil)
        #expect(layout.initialMethod(holding: []) == nil)
        #expect(layout.fields(for: nil).map { $0.id } == ["token"])
    }

    @Test("PostgreSQL's cloud and Kerberos secrets sit behind its Authentication menu")
    func postgresSignInSecretsAreGrouped() {
        let layout = ProfileSecretLayout(fields: KerberosAuthFields.standardWithAWSAndGoogleCloud())
        let method = layout.initialMethod(holding: [])

        #expect(layout.methodField?.id == "awsAuth")
        #expect(layout.fields(for: method).isEmpty)
        #expect(layout.fields(for: KerberosAuthFields.method).map { $0.id } == [KerberosAuthFields.passwordFieldId])
    }
}
