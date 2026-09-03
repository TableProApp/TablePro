//
//  HTMLExportOptionsView.swift
//  HTMLExportPlugin
//

import SwiftUI

struct HTMLExportOptionsView: View {
    @Bindable var plugin: HTMLExportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Write a full HTML document", isOn: $plugin.settings.writesFullDocument)
                .toggleStyle(.checkbox)
                .help("Off writes bare table elements, for pasting into a page that already has its own styling")

            Toggle("Write each table's name as a heading", isOn: $plugin.settings.includesTableNames)
                .toggleStyle(.checkbox)

            Toggle("Mark NULL cells", isOn: $plugin.settings.marksNulls)
                .toggleStyle(.checkbox)
                .help("An empty cell and a cell holding an empty string look the same, so a null is written as dimmed NULL text")
        }
        .font(.system(size: 13))
    }
}
