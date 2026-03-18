//
//  CSVExportOptionsView.swift
//  CSVExportPlugin
//

import SwiftUI

struct CSVExportOptionsView: View {
    @Bindable var plugin: CSVExportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Convert NULL to EMPTY", isOn: $plugin.settings.convertNullToEmpty)
                    .toggleStyle(.checkbox)

                Toggle("Convert line break to space", isOn: $plugin.settings.convertLineBreakToSpace)
                    .toggleStyle(.checkbox)

                Toggle("Put field names in the first row", isOn: $plugin.settings.includeFieldNames)
                    .toggleStyle(.checkbox)

                Toggle("Sanitize formula-like values", isOn: $plugin.settings.sanitizeFormulas)
                    .toggleStyle(.checkbox)
                    .help("Prevent CSV formula injection by prefixing values starting with =, +, -, @ with a single quote")
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 10) {
                optionRow(String(localized: "Delimiter", bundle: .main)) {
                    Picker("", selection: $plugin.settings.delimiter) {
                        ForEach(CSVDelimiter.allCases) { delimiter in
                            Text(delimiter.displayName).tag(delimiter)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140, alignment: .trailing)
                }

                optionRow(String(localized: "Quote", bundle: .main)) {
                    Picker("", selection: $plugin.settings.quoteHandling) {
                        ForEach(CSVQuoteHandling.allCases) { handling in
                            Text(handling.rawValue).tag(handling)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140, alignment: .trailing)
                }

                optionRow(String(localized: "Line break", bundle: .main)) {
                    Picker("", selection: $plugin.settings.lineBreak) {
                        ForEach(CSVLineBreak.allCases) { lineBreak in
                            Text(lineBreak.rawValue).tag(lineBreak)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140, alignment: .trailing)
                }

                optionRow(String(localized: "Decimal", bundle: .main)) {
                    Picker("", selection: $plugin.settings.decimalFormat) {
                        ForEach(CSVDecimalFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 13))
    }

    private func optionRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.primary)
                .frame(width: 80, alignment: .leading)
            Spacer()
            content()
        }
    }
}
