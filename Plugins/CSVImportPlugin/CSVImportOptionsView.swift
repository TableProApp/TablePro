//
//  CSVImportOptionsView.swift
//  CSVImportPlugin
//

import SwiftUI
import TableProPluginKit

struct CSVImportOptionsView: View {
    let plugin: CSVImportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Delimiter:", selection: Bindable(plugin).settings.delimiter) {
                Text("Auto-detect").tag(CSVImportOptions.Delimiter.auto)
                Text("Comma (,)").tag(CSVImportOptions.Delimiter.comma)
                Text("Semicolon (;)").tag(CSVImportOptions.Delimiter.semicolon)
                Text("Tab").tag(CSVImportOptions.Delimiter.tab)
                Text("Pipe (|)").tag(CSVImportOptions.Delimiter.pipe)
            }
            .pickerStyle(.menu)
            .font(.system(size: 13))

            Picker("Quote character:", selection: Bindable(plugin).settings.quoteCharacter) {
                Text("Double quote (\")").tag(CSVImportOptions.QuoteCharacter.doubleQuote)
                Text("Single quote (')").tag(CSVImportOptions.QuoteCharacter.singleQuote)
            }
            .pickerStyle(.menu)
            .font(.system(size: 13))

            Picker("Encoding:", selection: Bindable(plugin).settings.encoding) {
                Text("Auto-detect").tag(CSVImportOptions.TextEncoding.auto)
                Text("UTF-8").tag(CSVImportOptions.TextEncoding.utf8)
                Text("ISO Latin 1").tag(CSVImportOptions.TextEncoding.isoLatin1)
                Text("Windows-1252").tag(CSVImportOptions.TextEncoding.windowsCP1252)
            }
            .pickerStyle(.menu)
            .font(.system(size: 13))

            Toggle("First row is a header", isOn: Bindable(plugin).settings.hasHeaderRow)
                .font(.system(size: 13))
                .help("Use the first row as column names. Turn off to import every row as data.")

            Toggle("Trim leading and trailing spaces", isOn: Bindable(plugin).settings.trimWhitespace)
                .font(.system(size: 13))

            Toggle("Treat empty values as NULL", isOn: Bindable(plugin).settings.emptyAsNull)
                .font(.system(size: 13))
                .help("Insert NULL for empty fields instead of an empty string.")

            HStack(spacing: 8) {
                Text("NULL text:")
                TextField("", text: Bindable(plugin).settings.nullString, prompt: Text(verbatim: "\\N"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            .font(.system(size: 13))
            .help("An extra value that should be imported as NULL, for example \\N.")

            Picker("On error:", selection: Bindable(plugin).settings.errorHandling) {
                Text("Stop and Rollback").tag(ImportErrorHandling.stopAndRollback)
                Text("Stop and Commit").tag(ImportErrorHandling.stopAndCommit)
                Text("Skip and Continue").tag(ImportErrorHandling.skipAndContinue)
            }
            .pickerStyle(.menu)
            .font(.system(size: 13))

            Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: Bindable(plugin).settings.wrapInTransaction)
                .font(.system(size: 13))
                .disabled(plugin.settings.errorHandling == .skipAndContinue)
                .help(plugin.settings.errorHandling == .skipAndContinue
                    ? String(localized: "Not available in skip-and-continue mode")
                    : String(localized: "Insert all rows in a single transaction. If any row fails, all changes are rolled back."))

            Toggle("Delete existing rows before import", isOn: Bindable(plugin).settings.deleteExistingRows)
                .font(.system(size: 13))
                .help("Remove every row from the target table before inserting the imported rows.")
        }
    }
}
