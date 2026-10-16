//
//  CreateTableFormPreview.swift
//  TablePro
//

import SwiftUI
import TableProTheme

internal struct CreateTableFormPreview: View {
    internal let preview: CreateTableFormState.Preview
    internal let databaseType: DatabaseType

    internal var body: some View {
        Group {
            switch preview {
            case .statements(let text):
                DDLTextView(ddl: text, fontSize: .constant(13), databaseType: databaseType)
            case .message(let message):
                VStack(spacing: 8) {
                    Image(systemName: "doc.plaintext")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Stands in for the statement text view, so under a theme it keeps the editor's background.
                .themeBackground(.editorBackground, native: Color.clear, ignoresSafeAreaEdges: [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("create-table-form-preview")
    }
}
