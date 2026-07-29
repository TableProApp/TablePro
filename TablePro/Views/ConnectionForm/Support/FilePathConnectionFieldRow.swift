//
//  FilePathConnectionFieldRow.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct FilePathConnectionFieldRow: View {
    let field: ConnectionField
    @Binding var value: String
    let onBrowse: () -> Void

    static func isFilePathField(_ field: ConnectionField) -> Bool {
        field.fieldType == .text && field.id.hasSuffix("FilePath")
    }

    var body: some View {
        HStack {
            ConnectionFieldRow(field: field, value: $value)
            Button(String(localized: "Browse...")) {
                onBrowse()
            }
            .controlSize(.small)
        }
    }
}
