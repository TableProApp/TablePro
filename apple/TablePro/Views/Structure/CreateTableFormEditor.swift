//
//  CreateTableFormEditor.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

private enum CreateTableFormPane: CaseIterable {
    case form
    case preview

    var displayName: String {
        switch self {
        case .form: String(localized: "Form")
        case .preview: String(localized: "Preview")
        }
    }
}

internal struct CreateTableFormEditor: View {
    @ObservedObject internal var draft: CreateTableDraft
    internal let databaseType: DatabaseType
    internal let isCreating: Bool
    internal let generateStatements: (PluginCreateTableRequest) throws -> [String]
    internal let onCreate: () -> Void

    @State private var pane: CreateTableFormPane = .form

    internal var body: some View {
        if let form = draft.form {
            let issues = form.issues(tableName: draft.tableName)
            let messages = [form.submissionError?.message].compactMap { $0 } + issues.map(\.qualifiedMessage)
            VStack(spacing: 0) {
                TabView(selection: $pane) {
                    ForEach(CreateTableFormPane.allCases, id: \.self) { tab in
                        content(for: tab, form: form)
                            .tabItem { Text(tab.displayName) }
                            .tag(tab)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("create-table-form-tabs")
                .padding()

                HStack(spacing: 8) {
                    if let first = messages.first {
                        Label(first, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(messages.joined(separator: "\n"))
                            .accessibilityIdentifier("create-table-validation")
                    }

                    Spacer(minLength: 12)

                    Button(
                        isCreating ? String(localized: "Creating…") : String(localized: "Create Table"),
                        action: onCreate
                    )
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .disabled(!issues.isEmpty || isCreating)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("create-table-commit")
                }
                .padding([.horizontal, .bottom])
            }
        }
    }

    // Only the selected pane is built, so the preview asks the driver for statements only while it shows.
    @ViewBuilder
    private func content(for tab: CreateTableFormPane, form: CreateTableFormState) -> some View {
        if tab == pane {
            switch tab {
            case .form:
                CreateTableFormView(draft: draft)
            case .preview:
                CreateTableFormPreview(
                    preview: form.preview(tableName: draft.tableName, generate: generateStatements),
                    databaseType: databaseType
                )
            }
        } else {
            Color.clear
        }
    }
}
