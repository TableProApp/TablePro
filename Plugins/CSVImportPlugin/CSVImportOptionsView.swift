//
//  CSVImportOptionsView.swift
//  CSVImportPlugin
//

import SwiftUI
import TableProPluginKit

struct CSVImportOptionsView: View {
    let plugin: CSVImportPlugin

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Delimiter:")
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: Bindable(plugin).settings.delimiter) {
                        Text("Auto-detect").tag(CSVImportOptions.Delimiter.auto)
                        Text("Comma (,)").tag(CSVImportOptions.Delimiter.comma)
                        Text("Semicolon (;)").tag(CSVImportOptions.Delimiter.semicolon)
                        Text("Tab").tag(CSVImportOptions.Delimiter.tab)
                        Text("Pipe (|)").tag(CSVImportOptions.Delimiter.pipe)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 170)
                }

                GridRow {
                    Text("Quote character:")
                    Picker("", selection: Bindable(plugin).settings.quoteCharacter) {
                        Text("Double quote (\")").tag(CSVImportOptions.QuoteCharacter.doubleQuote)
                        Text("Single quote (')").tag(CSVImportOptions.QuoteCharacter.singleQuote)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 170)
                }

                GridRow {
                    Text("Encoding:")
                    Picker("", selection: Bindable(plugin).settings.encoding) {
                        Text("Auto-detect").tag(CSVImportOptions.TextEncoding.auto)
                        Text("UTF-8").tag(CSVImportOptions.TextEncoding.utf8)
                        Text("ISO Latin 1").tag(CSVImportOptions.TextEncoding.isoLatin1)
                        Text("Windows-1252").tag(CSVImportOptions.TextEncoding.windowsCP1252)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 170)
                }

                GridRow {
                    Text("On error:")
                    Picker("", selection: Bindable(plugin).settings.errorHandling) {
                        Text("Stop and Rollback").tag(ImportErrorHandling.stopAndRollback)
                        Text("Stop and Commit").tag(ImportErrorHandling.stopAndCommit)
                        Text("Skip and Continue").tag(ImportErrorHandling.skipAndContinue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 170)
                }

                GridRow {
                    Text("NULL text:")
                    TextField("", text: Bindable(plugin).settings.nullString, prompt: Text(verbatim: "\\N"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .help("An extra value that should be imported as NULL, for example \\N.")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("First row is a header", isOn: Bindable(plugin).settings.hasHeaderRow)
                    .help("Use the first row as column names. Turn off to import every row as data.")

                Toggle("Trim leading and trailing spaces", isOn: Bindable(plugin).settings.trimWhitespace)

                Toggle("Treat empty values as NULL", isOn: Bindable(plugin).settings.emptyAsNull)
                    .help("Insert NULL for empty fields instead of an empty string.")

                Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: Bindable(plugin).settings.wrapInTransaction)
                    .disabled(plugin.settings.errorHandling == .skipAndContinue)
                    .help(plugin.settings.errorHandling == .skipAndContinue
                        ? String(localized: "Not available in skip-and-continue mode")
                        : String(localized: "Insert all rows in a single transaction. If any row fails, all changes are rolled back."))

                Toggle("Delete existing rows before import", isOn: Bindable(plugin).settings.deleteExistingRows)
                    .help("Remove every row from the target table before inserting the imported rows.")
            }
        }
        .font(.system(size: 13))
    }
}
