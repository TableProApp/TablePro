//
//  UserTypeGeneralPane.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Name, comment and, for a domain, its default and NULL rule. Each field queues one change that
/// the next edit of the same field replaces, and typing the server's value back removes it.
struct UserTypeGeneralPane: View {
    @ObservedObject var model: UserTypeEditorModel
    let draft: UserTypeDraft
    let isDisabled: Bool

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Name"), text: binding(model.queuedName ?? draft.name) { .rename(to: $0) })
                    .disabled(isDisabled || !model.support.rename)
                    .accessibilityIdentifier("user-type-name")
                TextField(
                    String(localized: "Comment"),
                    text: binding(draft.comment ?? "") { .setComment($0) },
                    prompt: Text("None"),
                    axis: .vertical
                )
                .lineLimit(1...4)
                .disabled(isDisabled || !model.support.comment)
                .accessibilityIdentifier("user-type-comment")
            }
            if model.kind == .domain {
                Section(String(localized: "Domain")) {
                    LabeledContent(String(localized: "Base Type")) {
                        Text(model.serverType?.baseType ?? "")
                            .textSelection(.enabled)
                    }
                    TextField(
                        String(localized: "Default"),
                        text: binding(draft.defaultValue ?? "") { .setDefault($0) },
                        prompt: Text("None")
                    )
                    .disabled(isDisabled || !model.support.setDefault)
                    .accessibilityIdentifier("user-type-default")
                    Toggle(String(localized: "Not Null"), isOn: Binding(
                        get: { draft.isNotNull },
                        set: { model.stage(.setNotNull($0)) }
                    ))
                    .disabled(isDisabled || !model.support.setNotNull)
                    .accessibilityIdentifier("user-type-not-null")
                }
            } else if model.kind == .range, let subtype = model.serverType?.baseType {
                Section {
                    LabeledContent(String(localized: "Subtype")) {
                        Text(subtype).textSelection(.enabled)
                    }
                }
            }
            if let owner = model.serverType?.attributes.first(where: { $0.label == "Owner" }) {
                Section {
                    LabeledContent(String(localized: "Owner")) {
                        Text(owner.value).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(
        _ value: String,
        change: @escaping (String) -> PluginUserDefinedTypeChange
    ) -> Binding<String> {
        Binding(
            get: { value },
            set: { model.stage(change($0)) }
        )
    }
}
