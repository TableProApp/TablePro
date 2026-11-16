import SwiftUI
import TableProPluginKit
import TableProTabularIO

// Rows over the plugin's own `settings`, as on the Mac; the plugin saves what they write. "Delete existing rows
// first" belongs to the Insert write mode, so the destination section draws it with `DeleteExistingRowsToggle`.
struct ImportFormatOptionsSection: View {
    let plugin: any ImportFormatPlugin

    var body: some View {
        if let csv = plugin as? CSVImportPlugin {
            CSVImportOptionsForm(plugin: csv)
        } else if let json = plugin as? JSONImportPlugin {
            JSONImportOptionsForm(plugin: json)
        } else if let xlsx = plugin as? XLSXImportPlugin {
            XLSXImportOptionsForm(plugin: xlsx)
        } else if let sql = plugin as? SQLImportPlugin {
            SQLImportOptionsForm(plugin: sql)
        }
    }
}

struct DeleteExistingRowsToggle: View {
    let plugin: any ImportFormatPlugin

    var body: some View {
        if let csv = plugin as? CSVImportPlugin {
            CSVDeleteExistingToggle(plugin: csv)
        } else if let json = plugin as? JSONImportPlugin {
            JSONDeleteExistingToggle(plugin: json)
        } else if let xlsx = plugin as? XLSXImportPlugin {
            XLSXDeleteExistingToggle(plugin: xlsx)
        }
    }
}

// The plugin runs a clear before the rows whatever the write mode, so a mode that matches rows turns it off first.
enum ImportPluginSettings {
    static func deletesExistingRows(_ plugin: any ImportFormatPlugin) -> Bool {
        plugin.rowImportConfiguration?.deleteExistingRows ?? false
    }

    static func setDeletesExistingRows(_ deletes: Bool, on plugin: any ImportFormatPlugin) {
        if let csv = plugin as? CSVImportPlugin, csv.settings.deleteExistingRows != deletes {
            csv.settings.deleteExistingRows = deletes
        } else if let json = plugin as? JSONImportPlugin, json.settings.deleteExistingRows != deletes {
            json.settings.deleteExistingRows = deletes
        } else if let xlsx = plugin as? XLSXImportPlugin, xlsx.settings.deleteExistingRows != deletes {
            xlsx.settings.deleteExistingRows = deletes
        }
    }
}

private struct ErrorHandlingPicker: View {
    let selection: Binding<ImportErrorHandling>

    var body: some View {
        Picker("On error", selection: selection) {
            Text("Stop and Rollback").tag(ImportErrorHandling.stopAndRollback)
            Text("Stop and Commit").tag(ImportErrorHandling.stopAndCommit)
            Text("Skip and Continue").tag(ImportErrorHandling.skipAndContinue)
        }
        .pickerStyle(.menu)
    }
}

private struct TransactionFooter: View {
    let errorHandling: ImportErrorHandling

    var body: some View {
        if errorHandling == .skipAndContinue {
            Text("Not available in skip-and-continue mode")
        } else {
            Text("Insert all rows in a single transaction. If any row fails, all changes are rolled back.")
        }
    }
}

private struct CSVImportOptionsForm: View {
    @ObservedObject var plugin: CSVImportPlugin

    var body: some View {
        Section {
            Picker("Delimiter", selection: $plugin.settings.delimiter) {
                Text("Auto-detect").tag(CSVImportOptions.Delimiter.auto)
                Text("Comma (,)").tag(CSVImportOptions.Delimiter.comma)
                Text("Semicolon (;)").tag(CSVImportOptions.Delimiter.semicolon)
                Text("Tab").tag(CSVImportOptions.Delimiter.tab)
                Text("Pipe (|)").tag(CSVImportOptions.Delimiter.pipe)
            }
            .pickerStyle(.menu)
            Picker("Quote character", selection: $plugin.settings.quoteCharacter) {
                Text("Double quote (\")").tag(CSVImportOptions.QuoteCharacter.doubleQuote)
                Text("Single quote (')").tag(CSVImportOptions.QuoteCharacter.singleQuote)
            }
            .pickerStyle(.menu)
            Picker("Encoding", selection: $plugin.settings.encoding) {
                Text("Auto-detect").tag(CSVImportOptions.TextEncoding.auto)
                ForEach(CSVImportOptions.TextEncoding.allCases.filter { $0 != .auto }) { option in
                    Text(verbatim: option.tabularEncoding?.displayName ?? option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            Toggle("First row is a header", isOn: $plugin.settings.hasHeaderRow)
            Toggle("Trim leading and trailing spaces", isOn: $plugin.settings.trimWhitespace)
            Toggle("Treat empty values as NULL", isOn: $plugin.settings.emptyAsNull)
            LabeledContent("NULL text") {
                LiteralTextField(String("\\N"), text: $plugin.settings.nullString)
            }
        } header: {
            Text("CSV")
        } footer: {
            Text("An extra value that should be imported as NULL, for example \\N.")
        }
        Section {
            ErrorHandlingPicker(selection: $plugin.settings.errorHandling)
            Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: $plugin.settings.wrapInTransaction)
                .disabled(plugin.settings.errorHandling == .skipAndContinue)
        } footer: {
            TransactionFooter(errorHandling: plugin.settings.errorHandling)
        }
    }
}

private struct JSONImportOptionsForm: View {
    @ObservedObject var plugin: JSONImportPlugin

    var body: some View {
        Section {
            ErrorHandlingPicker(selection: $plugin.settings.errorHandling)
            Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: $plugin.settings.wrapInTransaction)
                .disabled(plugin.settings.errorHandling == .skipAndContinue)
        } footer: {
            TransactionFooter(errorHandling: plugin.settings.errorHandling)
        }
    }
}

private struct XLSXImportOptionsForm: View {
    @ObservedObject var plugin: XLSXImportPlugin

    var body: some View {
        Section {
            Toggle("First row holds column names", isOn: $plugin.settings.hasHeaderRow)
            Toggle("Trim whitespace", isOn: $plugin.settings.trimWhitespace)
            Toggle("Treat empty cells as NULL", isOn: $plugin.settings.emptyAsNull)
        } header: {
            Text("Excel")
        } footer: {
            Text("Off names the columns column1, column2 and so on")
        }
        Section {
            ErrorHandlingPicker(selection: $plugin.settings.errorHandling)
            Toggle("Wrap in transaction", isOn: $plugin.settings.wrapInTransaction)
                .disabled(plugin.settings.errorHandling == .skipAndContinue)
        } footer: {
            TransactionFooter(errorHandling: plugin.settings.errorHandling)
        }
    }
}

private struct SQLImportOptionsForm: View {
    @ObservedObject var plugin: SQLImportPlugin

    var body: some View {
        Section {
            ErrorHandlingPicker(selection: $plugin.settings.errorHandling)
            Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: $plugin.settings.wrapInTransaction)
                .disabled(plugin.settings.errorHandling == .skipAndContinue)
            Toggle("Disable foreign key checks", isOn: $plugin.settings.disableForeignKeyChecks)
        } footer: {
            if plugin.settings.errorHandling == .skipAndContinue {
                Text("Not available in skip-and-continue mode")
            } else {
                Text("""
                    Runs every statement in one transaction, so a failure rolls back what the import changed. A \
                    database that commits CREATE, ALTER and DROP as they run, such as MySQL, keeps those statements \
                    and everything before them.
                    """)
            }
        }
    }
}

private struct CSVDeleteExistingToggle: View {
    @ObservedObject var plugin: CSVImportPlugin

    var body: some View {
        Toggle("Delete existing rows first", isOn: $plugin.settings.deleteExistingRows)
    }
}

private struct JSONDeleteExistingToggle: View {
    @ObservedObject var plugin: JSONImportPlugin

    var body: some View {
        Toggle("Delete existing rows first", isOn: $plugin.settings.deleteExistingRows)
    }
}

private struct XLSXDeleteExistingToggle: View {
    @ObservedObject var plugin: XLSXImportPlugin

    var body: some View {
        Toggle("Delete existing rows first", isOn: $plugin.settings.deleteExistingRows)
    }
}

// The fields come from a read of the file that depends on parsing options (delimiter, header, encoding), so a change
// to them reads the file again.
struct ImportDetectionSignatureObserver: View {
    let plugin: any ImportFormatPlugin
    let onChange: () -> Void

    var body: some View {
        if let csv = plugin as? CSVImportPlugin {
            SignatureWatch(plugin: csv, onChange: onChange)
        } else if let xlsx = plugin as? XLSXImportPlugin {
            SignatureWatch(plugin: xlsx, onChange: onChange)
        } else if let json = plugin as? JSONImportPlugin {
            SignatureWatch(plugin: json, onChange: onChange)
        }
    }
}

private struct SignatureWatch<Plugin: ImportFormatPlugin & ObservableObject>: View {
    @ObservedObject var plugin: Plugin
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: plugin.fieldDetectionSignature) { onChange() }
    }
}
