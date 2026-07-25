//
//  ImportFromURLSheet.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

struct ImportFromURLSheet: View {
    let onImported: (ParsedConnectionURL) -> Void
    let onCancel: () -> Void

    @State private var urlString: String = ""
    @State private var parseError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Import from URL"))
                    .font(.headline)
                Text(String(localized: "Paste a connection URL. We'll detect the database type and pre-fill the form."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField(
                String(localized: "Connection URL"),
                text: $urlString,
                prompt: Text(verbatim: "mysql://user:password@host:3306/database")
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(submit)

            if let parseError {
                Label(parseError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let parsed = parsedURL {
                ParsedConnectionSummaryView(parsed: parsed)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Import")) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 260)
        .onAppear(perform: prefillFromClipboard)
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedURL: ParsedConnectionURL? {
        guard !trimmedURL.isEmpty else { return nil }
        if case .success(let parsed) = ConnectionURLParser.parse(trimmedURL) {
            return parsed
        }
        return nil
    }

    private func submit() {
        guard !trimmedURL.isEmpty else { return }
        switch ConnectionURLParser.parse(trimmedURL) {
        case .success(let parsed):
            parseError = nil
            onImported(parsed)
            dismiss()
        case .failure(let error):
            parseError = error.localizedDescription
        }
    }

    private func prefillFromClipboard() {
        guard urlString.isEmpty,
              let clipString = NSPasteboard.general.string(forType: .string),
              let firstLine = clipString.components(separatedBy: .newlines).first,
              firstLine.contains("://") else { return }
        urlString = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
