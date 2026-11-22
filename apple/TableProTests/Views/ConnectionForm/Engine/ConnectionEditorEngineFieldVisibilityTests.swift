//
//  ConnectionEditorEngineFieldVisibilityTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorEngineFieldVisibilityTests {
    private func field(
        _ id: String,
        section: FieldSection,
        required: Bool = false,
        defaultValue: String? = nil,
        type: ConnectionField.FieldType = .text,
        hidesPassword: Bool = false,
        visibleWhen: FieldVisibilityRule? = nil
    ) -> ConnectionField {
        ConnectionField(
            id: id,
            label: id,
            required: required,
            defaultValue: defaultValue,
            fieldType: type,
            section: section,
            hidesPassword: hidesPassword,
            visibleWhen: visibleWhen
        )
    }

    private func traits(_ fields: [ConnectionField]) -> ConnectionTypeTraits {
        var traits = ConnectionTypeTraits(type: DatabaseType(rawValue: "Probe"))
        traits.fields = fields
        return traits
    }

    private func draft(_ traits: ConnectionTypeTraits, values: [String: String] = [:]) -> ConnectionDraft {
        var draft = ConnectionDraft.new(type: traits.type, traits: traits)
        draft.name = "Probe"
        for (id, value) in values {
            draft.setFieldValue(value, for: id)
        }
        return draft
    }

    private func pluginRows(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, facet: ConnectionFacet, section: String)
        -> [String] {
        let layout = ConnectionEditorEngine.layout(draft, traits, EditorContext())
        let rows = layout.facet(facet)?.sections.first { $0.id == section }?.rows ?? []
        return rows.compactMap(\.pluginFieldID)
    }

    private func messages(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, on fieldId: String, _ context: EditorContext = EditorContext())
        -> [String] {
        ConnectionEditorEngine.issues(draft, traits, context)
            .filter { $0.row == .plugin(fieldID: fieldId) }
            .map(\.message)
    }

    private func modeDropdown(_ id: String = "mode", values: [String], defaultValue: String) -> ConnectionField {
        let options = values.map { ConnectionField.DropdownOption(value: $0, label: $0.uppercased()) }
        return field(id, section: .connection, defaultValue: defaultValue, type: .dropdown(options: options))
    }

    @Test("Plugin rows land in their section and follow their visibility rule")
    func visibleFieldsFilterBySectionAndVisibility() {
        let traits = traits([
            field("host", section: .connection),
            modeDropdown(values: ["a", "b"], defaultValue: "a"),
            field("sentinel", section: .connection, visibleWhen: .init(fieldId: "mode", values: ["b"])),
            field("extra", section: .advanced),
        ])
        let hidden = draft(traits, values: ["mode": "a"])
        #expect(pluginRows(hidden, traits, facet: .general, section: "connection") == ["host", "mode"])
        #expect(pluginRows(hidden, traits, facet: .advanced, section: "driver") == ["extra"])

        let shown = draft(traits, values: ["mode": "b"])
        #expect(pluginRows(shown, traits, facet: .general, section: "connection") == ["host", "mode", "sentinel"])
    }

    // The controller lives in Connection and the secret it gates in Authentication: one flat value bag sees both.
    @Test("A visibility rule resolves across sections")
    func crossSectionVisibleWhenResolvesAgainstMergedValues() {
        let secret = field(
            "sentinelPassword",
            section: .authentication,
            type: .secure,
            visibleWhen: .init(fieldId: "mode", values: ["sentinel"])
        )
        let traits = traits([modeDropdown(values: ["standalone", "sentinel"], defaultValue: "standalone"), secret])
        #expect(!ConnectionEditorEngine.isVisible(secret, draft(traits), traits))
        #expect(!pluginRows(draft(traits), traits, facet: .general, section: "authentication").contains("sentinelPassword"))

        let sentinel = draft(traits, values: ["mode": "sentinel"])
        #expect(ConnectionEditorEngine.isVisible(secret, sentinel, traits))
        #expect(pluginRows(sentinel, traits, facet: .general, section: "authentication").contains("sentinelPassword"))
    }

    // "Use ~/.pgpass" sat between Username and Method, and the method picker under the credentials it decides.
    @Test("Authentication reads Method, Credentials, Username, Password, then the switch that stands in for the password")
    func authenticationRowOrder() {
        let traits = traits([
            field("usePgpass", section: .authentication, type: .toggle, hidesPassword: true),
            field(
                "authMethod",
                section: .authentication,
                defaultValue: "password",
                type: .dropdown(options: [.init(value: "password", label: "Password"), .init(value: "sso", label: "SSO")]),
                hidesPassword: true
            ),
        ])
        let rows = ConnectionEditorEngine.layout(draft(traits), traits, EditorContext())
            .facet(.general)?.sections.first { $0.id == "authentication" }?.rows

        #expect(rows == [
            .plugin(fieldID: "authMethod"),
            .builtIn(.credentialProfile),
            .builtIn(.username),
            .builtIn(.passwordMode),
            .builtIn(.password),
            .plugin(fieldID: "usePgpass"),
        ])
    }

    @Test("PostgreSQL's Authentication puts ~/.pgpass after Password")
    func postgresPgpassFollowsPassword() throws {
        let postgres = ConnectionTypeTraits.live(for: .postgresql, pluginManager: .shared)
        try #require(postgres.field("usePgpass") != nil)
        let rows = ConnectionEditorEngine.layout(draft(postgres), postgres, EditorContext())
            .facet(.general)?.sections.first { $0.id == "authentication" }?.rows ?? []
        let pgpass = try #require(rows.firstIndex(of: .plugin(fieldID: "usePgpass")))
        let password = try #require(rows.firstIndex(of: .builtIn(.password)))
        let credentials = try #require(rows.firstIndex(of: .builtIn(.credentialProfile)))

        #expect(password < pgpass)
        if let method = rows.firstIndex(of: .plugin(fieldID: "awsAuth")) {
            #expect(method < credentials)
        }
    }

    @Test("A dropdown off its default, a toggle that is on, or the type itself hides the password")
    func hidesPasswordFromDropdownToggleAndType() {
        let dropdown = traits([field(
            "authMethod",
            section: .authentication,
            defaultValue: "password",
            type: .dropdown(options: [.init(value: "password", label: "Password"), .init(value: "sso", label: "SSO")]),
            hidesPassword: true
        )])
        let atDefault = draft(dropdown, values: ["authMethod": "password"])
        #expect(!ConnectionEditorEngine.hidesPassword(atDefault, dropdown))
        #expect(ConnectionEditorEngine.layout(atDefault, dropdown, EditorContext()).contains(.builtIn(.password)))
        let sso = draft(dropdown, values: ["authMethod": "sso"])
        #expect(ConnectionEditorEngine.hidesPassword(sso, dropdown))
        #expect(!ConnectionEditorEngine.layout(sso, dropdown, EditorContext()).contains(.builtIn(.password)))

        let toggle = traits([field("usePgpass", section: .authentication, type: .toggle, hidesPassword: true)])
        #expect(ConnectionEditorEngine.hidesPassword(draft(toggle, values: ["usePgpass": "true"]), toggle))
        #expect(!ConnectionEditorEngine.hidesPassword(draft(toggle), toggle))

        var hiddenByType = traits([])
        hiddenByType.hidesBuiltInPassword = true
        #expect(ConnectionEditorEngine.hidesPassword(draft(hiddenByType), hiddenByType))
    }

    @Test("Required and range rules raise an issue on their own row, and a linked profile supplies its secure field")
    func requiredAndRangeValidation() {
        let traits = traits([
            field("token", section: .authentication, required: true, type: .secure),
            field("database", section: .connection, required: true, defaultValue: "postgres"),
            field("poolSize", section: .advanced, type: .stepper(range: .init(1...10))),
        ])
        let empty = draft(traits, values: ["poolSize": "99"])
        #expect(messages(empty, traits, on: "token") == ["token is required"])
        #expect(messages(empty, traits, on: "database").isEmpty)
        #expect(messages(empty, traits, on: "poolSize") == ["poolSize must be between 1 and 10"])

        let profile = CredentialProfile(name: "Shared", secureFieldIds: ["token"])
        var context = EditorContext()
        context.credentialProfiles = [profile]
        var linked = empty
        linked.setCredentialMode(.profile(id: profile.id))
        #expect(messages(linked, traits, on: "token", context).isEmpty)

        let filled = draft(traits, values: ["token": "abc", "poolSize": "5"])
        #expect(messages(filled, traits, on: "token").isEmpty)
        #expect(messages(filled, traits, on: "poolSize").isEmpty)
    }

    @Test("A required field its rule hides does not block")
    func requiredHiddenFieldDoesNotBlock() {
        let traits = traits([
            modeDropdown(values: ["a", "b"], defaultValue: "a"),
            field("onlyForB", section: .connection, required: true, visibleWhen: .init(fieldId: "mode", values: ["b"])),
        ])
        #expect(messages(draft(traits, values: ["mode": "a"]), traits, on: "onlyForB").isEmpty)
        #expect(messages(draft(traits, values: ["mode": "b"]), traits, on: "onlyForB") == ["onlyForB is required"])
    }

    // The editor seeds every section's defaults once; the old per-section seeding is gone with the panes.
    @Test("A new connection starts with the default of every field that has one")
    func defaultValuesSeedEverySection() {
        let traits = traits([
            field("a", section: .connection, defaultValue: "1"),
            field("b", section: .advanced, defaultValue: "2"),
            field("c", section: .advanced),
        ])
        #expect(traits.defaultValues() == ["a": "1", "b": "2"])
        #expect(ConnectionDraft.new(type: traits.type, traits: traits).fieldValues == ["a": "1", "b": "2"])
    }

    @Test("Two fields gating each other neither recurse nor hide each other")
    func visibilityCycleTerminates() {
        let x = field("x", section: .connection, visibleWhen: .init(fieldId: "y", values: ["on"]))
        let y = field("y", section: .connection, visibleWhen: .init(fieldId: "x", values: ["on"]))
        let traits = traits([x, y])
        let both = draft(traits, values: ["x": "on", "y": "on"])
        #expect(ConnectionEditorEngine.isVisible(x, both, traits))
        #expect(ConnectionEditorEngine.isVisible(y, both, traits))
        #expect(pluginRows(both, traits, facet: .general, section: "connection") == ["x", "y"])
    }
}
