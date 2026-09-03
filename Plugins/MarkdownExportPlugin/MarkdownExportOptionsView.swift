//
//  MarkdownExportOptionsView.swift
//  MarkdownExportPlugin
//

import SwiftUI

struct MarkdownExportOptionsView: View {
    @Bindable var plugin: MarkdownExportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Align columns", isOn: $plugin.settings.alignsColumns)
                .toggleStyle(.checkbox)
                .help("Pads cells so the columns line up in the raw text. Widths come from the header and the first 200 rows")

            Toggle("Write each table's name as a heading", isOn: $plugin.settings.includesTableNames)
                .toggleStyle(.checkbox)

            HStack {
                Text("NULL shows as")
                Spacer()
                TextField("NULL", text: $plugin.settings.nullPlaceholder)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }
            .help("An empty Markdown cell and a cell holding an empty string render the same, so a null needs its own text")
        }
        .font(.system(size: 13))
    }
}
