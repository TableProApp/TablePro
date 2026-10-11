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

                    Picker(String(localized: "View"), selection: $pane) {
                        ForEach(CreateTableFormPane.allCases, id: \.self) { pane in
                            Text(pane.displayName).tag(pane)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()

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
                .padding()

                Divider()

                switch pane {
                case .form:
                    CreateTableFormView(draft: draft)
                case .preview:
                    CreateTableFormPreview(
                        preview: form.preview(tableName: draft.tableName, generate: generateStatements),
                        databaseType: databaseType
                    )
                }
            }
        }
    }
}
