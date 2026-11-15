import SwiftUI
import TableProPluginKit

// The plugin's own `settings` are the model: these rows write into it and the plugin saves it, so iOS keeps no
// second copy of any option.
struct ExportFormatOptionsSection: View {
    let plugin: any ExportFormatPlugin

    var body: some View {
        if let csv = plugin as? CSVExportPlugin {
            CSVExportOptionsForm(plugin: csv)
        } else if let json = plugin as? JSONExportPlugin {
            JSONExportOptionsForm(plugin: json)
        } else if let sql = plugin as? SQLExportPlugin {
            SQLExportOptionsForm(plugin: sql)
        } else if let xlsx = plugin as? XLSXExportPlugin {
            XLSXExportOptionsForm(plugin: xlsx)
        } else if let markdown = plugin as? MarkdownExportPlugin {
            MarkdownExportOptionsForm(plugin: markdown)
        } else if let mql = plugin as? MQLExportPlugin {
            MQLExportOptionsForm(plugin: mql)
        }
    }
}

private struct CSVExportOptionsForm: View {
    @ObservedObject var plugin: CSVExportPlugin

    var body: some View {
        Section {
            Picker("Delimiter", selection: $plugin.settings.delimiter) {
                Text("Comma (,)").tag(CSVDelimiter.comma)
                Text("Semicolon (;)").tag(CSVDelimiter.semicolon)
                Text("Tab").tag(CSVDelimiter.tab)
                Text("Pipe (|)").tag(CSVDelimiter.pipe)
            }
            .pickerStyle(.menu)
            Picker("Quote", selection: $plugin.settings.quoteHandling) {
                ForEach(CSVQuoteHandling.allCases) { handling in
                    Text(verbatim: handling.displayName).tag(handling)
                }
            }
            .pickerStyle(.menu)
            Picker("Line break", selection: $plugin.settings.lineBreak) {
                ForEach(CSVLineBreak.allCases) { lineBreak in
                    Text(verbatim: lineBreak.rawValue).tag(lineBreak)
                }
            }
            .pickerStyle(.menu)
            Picker("Decimal", selection: $plugin.settings.decimalFormat) {
                ForEach(CSVDecimalFormat.allCases) { format in
                    Text(verbatim: format.rawValue).tag(format)
                }
            }
            .pickerStyle(.menu)
            Toggle("Put field names in the first row", isOn: $plugin.settings.includeFieldNames)
            Toggle("Convert NULL to EMPTY", isOn: $plugin.settings.convertNullToEmpty)
            Toggle("Convert line break to space", isOn: $plugin.settings.convertLineBreakToSpace)
        } header: {
            Text("CSV")
        }
        Section {
            Picker("Encoding", selection: $plugin.settings.encoding) {
                ForEach(PluginTextEncoding.allCases) { encoding in
                    Text(verbatim: encoding.displayName).tag(encoding)
                }
            }
            .pickerStyle(.menu)
            Toggle("Include byte order mark", isOn: $plugin.settings.writesByteOrderMark)
                .disabled(!plugin.settings.encoding.supportsByteOrderMark)
        } footer: {
            Text("Excel on Windows needs this to read UTF-8. Other readers show it as part of the first value.")
        }
        Section {
            Toggle("Sanitize formula-like values", isOn: $plugin.settings.sanitizeFormulas)
        } footer: {
            Text("""
                For a file opened in a spreadsheet. Values that would run as formulas, such as those starting \
                with =, +, - or @, get a leading single quote, which stays in the value for anything that \
                imports the file.
                """)
        }
    }
}

private struct JSONExportOptionsForm: View {
    @ObservedObject var plugin: JSONExportPlugin

    var body: some View {
        Section {
            Picker("Layout", selection: $plugin.settings.layout) {
                ForEach(JSONExportLayout.allCases) { layout in
                    Text(verbatim: layout.label).tag(layout)
                }
            }
            .pickerStyle(.menu)
            Toggle("Pretty print (formatted output)", isOn: $plugin.settings.prettyPrint)
                .disabled(plugin.settings.layout == .newlineDelimited)
            Toggle("Include NULL values", isOn: $plugin.settings.includeNullValues)
            Toggle("Preserve all values as strings", isOn: $plugin.settings.preserveAllAsStrings)
        } header: {
            Text("JSON")
        } footer: {
            Text("Keep leading zeros in ZIP codes, phone numbers, and IDs by outputting all values as strings")
        }
    }
}

private struct SQLExportOptionsForm: View {
    @ObservedObject var plugin: SQLExportPlugin

    var body: some View {
        Section {
            Picker("Rows per INSERT", selection: $plugin.settings.batchSize) {
                ForEach(SQLExportOptions.batchSizeChoices, id: \.self) { size in
                    if size == 1 {
                        Text("1 (no batching)").tag(size)
                    } else {
                        Text(verbatim: "\(size)").tag(size)
                    }
                }
            }
            .pickerStyle(.menu)
            Picker("Max INSERT size", selection: $plugin.settings.maxStatementBytes) {
                ForEach(SQLExportOptions.statementSizeChoices, id: \.self) { size in
                    Text(verbatim: SQLExportOptions.statementSizeLabel(size)).tag(size)
                }
            }
            .pickerStyle(.menu)
            Picker("On existing rows", selection: $plugin.settings.insertMode) {
                ForEach(SQLExportInsertMode.allCases) { mode in
                    Text(verbatim: mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Picker("Split every", selection: $plugin.settings.splitSizeMegabytes) {
                ForEach(SQLExportOptions.splitSizeChoices, id: \.self) { size in
                    if size == 0 {
                        Text("One file").tag(size)
                    } else {
                        Text(verbatim: "\(size) MB").tag(size)
                    }
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("SQL")
        }
        Section {
            Toggle("Read every table at one snapshot", isOn: $plugin.settings.consistentSnapshot)
            Toggle("Exclude the AUTO_INCREMENT counter", isOn: $plugin.settings.excludeAutoIncrementValue)
            Toggle("Exclude DEFINER clauses", isOn: $plugin.settings.excludeDefiner)
            Toggle("Compress the file using Gzip", isOn: $plugin.settings.compressWithGzip)
        } footer: {
            Text("AUTO_INCREMENT and DEFINER apply to MySQL and MariaDB.")
        }
    }
}

private struct XLSXExportOptionsForm: View {
    @ObservedObject var plugin: XLSXExportPlugin

    var body: some View {
        Section {
            Toggle("Include column headers", isOn: $plugin.settings.includeHeaderRow)
            Toggle("Convert NULL to empty", isOn: $plugin.settings.convertNullToEmpty)
        } header: {
            Text("Excel")
        }
    }
}

private struct MarkdownExportOptionsForm: View {
    @ObservedObject var plugin: MarkdownExportPlugin

    var body: some View {
        Section {
            Toggle("Align columns", isOn: $plugin.settings.alignsColumns)
            Toggle("Write each table's name as a heading", isOn: $plugin.settings.includesTableNames)
            LabeledContent("NULL shows as") {
                LiteralTextField(String("NULL"), text: $plugin.settings.nullPlaceholder)
            }
        } header: {
            Text("Markdown")
        } footer: {
            Text("An empty Markdown cell and a cell holding an empty string render the same, so a null needs its own text")
        }
    }
}

private struct MQLExportOptionsForm: View {
    @ObservedObject var plugin: MQLExportPlugin

    var body: some View {
        Section {
            Picker("Rows per batch", selection: $plugin.settings.batchSize) {
                ForEach(MQLExportOptions.batchSizeChoices, id: \.self) { size in
                    Text(verbatim: "\(size)").tag(size)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("MQL")
        } footer: {
            Text("Maximum documents per batch. Large documents use smaller batches to fit the server limit.")
        }
    }
}
