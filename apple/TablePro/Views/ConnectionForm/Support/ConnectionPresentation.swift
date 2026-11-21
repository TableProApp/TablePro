import Foundation
import TableProPluginKit

/// Pure presentation logic for a connection's plugin-declared fields.
///
/// One place for section filtering, field visibility, default seeding and required/range
/// validation. `NetworkPaneViewModel`, `AuthPaneViewModel` and `AdvancedPaneViewModel` each
/// re-derived all of this from the same field list, and the password-hiding and visibility
/// checks disagreed on which value dictionary to read. Feeding one flat value dictionary makes a
/// cross-section `visibleWhen` rule resolve, and gives `hidesPassword` a single answer.
struct ConnectionPresentation {
    /// Every additional field the plugin declares for the type, all sections.
    let fields: [ConnectionField]
    /// The merged values across all sections, keyed by field id.
    let values: [String: String]
    /// The app-side snapshot flag: this plugin's form never offers the built-in password.
    let hidesBuiltInPassword: Bool

    init(fields: [ConnectionField], values: [String: String], hidesBuiltInPassword: Bool = false) {
        self.fields = fields
        self.values = values
        self.hidesBuiltInPassword = hidesBuiltInPassword
    }

    func fields(in section: FieldSection) -> [ConnectionField] {
        fields.filter { $0.section == section }
    }

    func isVisible(_ field: ConnectionField) -> Bool {
        fields.isVisible(field, forValues: values)
    }

    func visibleFields(in section: FieldSection) -> [ConnectionField] {
        fields(in: section).filter(isVisible)
    }

    var hidesPassword: Bool {
        hidesBuiltInPassword || fields.hidesPassword(forValues: values)
    }

    var hidesUsername: Bool {
        fields.hidesUsername(forValues: values)
    }

    /// The default value for every field, optionally one section. Replaces the per-view-model
    /// seeding loops in `resetForType` and the default half of `load(from:)`.
    func defaultValues(in section: FieldSection? = nil) -> [String: String] {
        var seeded: [String: String] = [:]
        for field in fields where section == nil || field.section == section {
            if let value = field.defaultValue {
                seeded[field.id] = value
            }
        }
        return seeded
    }

    /// Required-empty and out-of-range issues for a section's visible fields, in the words the user
    /// needs. `excludingRequired` skips ids a linked credential profile supplies at connect, so an
    /// empty copy of a profile field does not block Save.
    func validationIssues(in section: FieldSection, excludingRequired excluded: Set<String> = []) -> [String] {
        var issues: [String] = []
        // Content fields (loadable extensions, attached databases) carry their own editors and
        // validators, so the generic required/range check skips them.
        let visible = visibleFields(in: section).filter { $0.content == .plain }
        for field in visible where field.isRequired && !excluded.contains(field.id) {
            let value = values[field.id] ?? field.defaultValue ?? ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(String(format: String(localized: "%@ is required"), field.label))
            }
        }
        issues += visible.compactMap { $0.rangeIssue(in: values[$0.id] ?? "") }
        return issues
    }
}
