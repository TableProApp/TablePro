//
//  DataDictionaryExportOptionsView.swift
//  DataDictionaryExportPlugin
//

import SwiftUI

struct DataDictionaryExportOptionsView: View {
    @ObservedObject var plugin: DataDictionaryExportPlugin

    var body: some View {
        Picker(String(localized: "Write as", bundle: .main), selection: $plugin.settings.fileType) {
            Text(verbatim: "Markdown").tag(DataDictionaryFileType.markdown)
            Text(verbatim: "HTML").tag(DataDictionaryFileType.html)
        }
        .pickerStyle(.radioGroup)
        .help(String(
            localized: "Markdown has a table of contents for a README or a wiki. HTML is one file that opens in any browser and prints.",
            bundle: .main
        ))
        .font(.system(size: 13))
    }
}
