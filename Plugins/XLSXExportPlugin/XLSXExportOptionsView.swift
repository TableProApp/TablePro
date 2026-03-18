//
//  XLSXExportOptionsView.swift
//  XLSXExportPlugin
//

import SwiftUI

struct XLSXExportOptionsView: View {
    @Bindable var plugin: XLSXExportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include column headers", isOn: $plugin.settings.includeHeaderRow)
                .toggleStyle(.checkbox)

            Toggle("Convert NULL to empty", isOn: $plugin.settings.convertNullToEmpty)
                .toggleStyle(.checkbox)
        }
        .font(.system(size: 13))
    }
}
