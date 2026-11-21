import Testing
import TableProPluginKit
@testable import TablePro

struct ConnectionPresentationTests {
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

    @Test func visibleFieldsFilterBySectionAndVisibility() {
        let fields = [
            field("host", section: .connection),
            field("mode", section: .connection, defaultValue: "a", type: .dropdown(options: [
                .init(value: "a", label: "A"), .init(value: "b", label: "B"),
            ])),
            field("sentinel", section: .connection, visibleWhen: .init(fieldId: "mode", values: ["b"])),
            field("extra", section: .advanced),
        ]
        let hidden = ConnectionPresentation(fields: fields, values: ["mode": "a"])
        #expect(hidden.visibleFields(in: .connection).map(\.id) == ["host", "mode"])
        #expect(hidden.visibleFields(in: .advanced).map(\.id) == ["extra"])

        let shown = ConnectionPresentation(fields: fields, values: ["mode": "b"])
        #expect(shown.visibleFields(in: .connection).map(\.id) == ["host", "mode", "sentinel"])
    }

    @Test func crossSectionVisibleWhenResolvesAgainstMergedValues() {
        // The controller lives in .connection, the controlled secret in .authentication: the sharded
        // per-pane dictionaries could not see across sections, this engine takes one flat dict.
        let fields = [
            field("mode", section: .connection, defaultValue: "standalone", type: .dropdown(options: [
                .init(value: "standalone", label: "Standalone"), .init(value: "sentinel", label: "Sentinel"),
            ])),
            field("sentinelPassword", section: .authentication, type: .secure,
                  visibleWhen: .init(fieldId: "mode", values: ["sentinel"])),
        ]
        #expect(!ConnectionPresentation(fields: fields, values: ["mode": "standalone"])
            .isVisible(fields[1]))
        #expect(ConnectionPresentation(fields: fields, values: ["mode": "sentinel"])
            .isVisible(fields[1]))
    }

    @Test func hidesPasswordFromDropdownToggleAndControllerChain() {
        let dropdown = field("authMethod", section: .authentication, defaultValue: "password",
                             type: .dropdown(options: [
                                .init(value: "password", label: "Password"),
                                .init(value: "sso", label: "SSO"),
                             ]), hidesPassword: true)
        // Dropdown at its default does not hide; off-default hides.
        #expect(!ConnectionPresentation(fields: [dropdown], values: ["authMethod": "password"]).hidesPassword)
        #expect(ConnectionPresentation(fields: [dropdown], values: ["authMethod": "sso"]).hidesPassword)

        let toggle = field("usePgpass", section: .authentication, type: .toggle, hidesPassword: true)
        #expect(ConnectionPresentation(fields: [toggle], values: ["usePgpass": "true"]).hidesPassword)
        #expect(!ConnectionPresentation(fields: [toggle], values: [:]).hidesPassword)

        // The snapshot flag hides regardless of fields.
        #expect(ConnectionPresentation(fields: [], values: [:], hidesBuiltInPassword: true).hidesPassword)
    }

    @Test func requiredAndRangeValidation() {
        let fields = [
            field("token", section: .authentication, required: true, type: .secure),
            field("database", section: .connection, required: true, defaultValue: "postgres"),
            field("poolSize", section: .advanced, type: .stepper(range: .init(1...10))),
        ]
        let empty = ConnectionPresentation(fields: fields, values: ["poolSize": "99"])
        // token required + empty -> an issue; database has a default so no issue.
        #expect(empty.validationIssues(in: .authentication) == ["token is required"])
        #expect(empty.validationIssues(in: .connection).isEmpty)
        #expect(empty.validationIssues(in: .advanced) == ["poolSize must be between 1 and 10"])

        // A linked credential profile supplies the field at connect: excluding it drops the issue.
        #expect(empty.validationIssues(in: .authentication, excludingRequired: ["token"]).isEmpty)

        let filled = ConnectionPresentation(fields: fields, values: ["token": "abc", "poolSize": "5"])
        #expect(filled.validationIssues(in: .authentication).isEmpty)
        #expect(filled.validationIssues(in: .advanced).isEmpty)
    }

    @Test func requiredHiddenFieldDoesNotBlock() {
        let fields = [
            field("mode", section: .connection, defaultValue: "a", type: .dropdown(options: [
                .init(value: "a", label: "A"), .init(value: "b", label: "B"),
            ])),
            field("onlyForB", section: .connection, required: true,
                  visibleWhen: .init(fieldId: "mode", values: ["b"])),
        ]
        #expect(ConnectionPresentation(fields: fields, values: ["mode": "a"]).validationIssues(in: .connection).isEmpty)
        #expect(ConnectionPresentation(fields: fields, values: ["mode": "b"]).validationIssues(in: .connection) == ["onlyForB is required"])
    }

    @Test func defaultValuesSeedPerSectionAndAll() {
        let fields = [
            field("a", section: .connection, defaultValue: "1"),
            field("b", section: .advanced, defaultValue: "2"),
            field("c", section: .advanced),
        ]
        let p = ConnectionPresentation(fields: fields, values: [:])
        #expect(p.defaultValues(in: .connection) == ["a": "1"])
        #expect(p.defaultValues(in: .advanced) == ["b": "2"])
        #expect(p.defaultValues() == ["a": "1", "b": "2"])
    }

    @Test func visibilityCycleTerminates() {
        // Two fields each gating the other: must not recurse forever.
        let fields = [
            field("x", section: .connection, visibleWhen: .init(fieldId: "y", values: ["on"])),
            field("y", section: .connection, visibleWhen: .init(fieldId: "x", values: ["on"])),
        ]
        let p = ConnectionPresentation(fields: fields, values: ["x": "on", "y": "on"])
        #expect(p.isVisible(fields[0]))
        #expect(p.isVisible(fields[1]))
    }
}
