//
//  XMLExportOptionsView.swift
//  XMLExportPlugin
//

import SwiftUI

struct XMLExportOptionsView: View {
    @Bindable var plugin: XMLExportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Pretty print (indented)", isOn: $plugin.settings.prettyPrint)
                .toggleStyle(.checkbox)

            Toggle("Mark NULL with xsi:nil", isOn: $plugin.settings.marksNulls)
                .toggleStyle(.checkbox)
                .help("An omitted element cannot be told apart from a column that was never selected")

            HStack {
                Text("Row element")
                Spacer()
                TextField("row", text: $plugin.settings.rowElementName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }
        }
        .font(.system(size: 13))
    }
}
