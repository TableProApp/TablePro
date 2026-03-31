//
//  JSONEditorContentView.swift
//  TablePro
//
//  SwiftUI popover content for editing JSON/JSONB column values with formatting and validation.
//

import SwiftUI

struct JSONEditorContentView: View {
    let initialValue: String?
    let onCommit: (String) -> Void
    let onDismiss: () -> Void

    @State private var text: String
    @State private var showInvalidAlert = false

    init(
        initialValue: String?,
        onCommit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initialValue = initialValue
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._text = State(initialValue: initialValue ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            JSONSyntaxTextView(text: $text, wordWrap: true)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveJSON() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 420, height: 340)
        .alert("Invalid JSON", isPresented: $showInvalidAlert) {
            Button("Save Anyway") { commitAndClose(text) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The text is not valid JSON. Save anyway?")
        }
    }

    // MARK: - Actions

    private func saveJSON() {
        guard !text.isEmpty else {
            commitAndClose(text)
            return
        }

        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            showInvalidAlert = true
            return
        }

        commitAndClose(text)
    }

    private func commitAndClose(_ value: String) {
        let saveValue = Self.compact(value) ?? value
        if saveValue != initialValue {
            onCommit(saveValue)
        }
        onDismiss()
    }

    // MARK: - JSON Helpers

    private static func compact(_ jsonString: String?) -> String? {
        guard let data = jsonString?.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let compactData = try? JSONSerialization.data(
                  withJSONObject: jsonObject,
                  options: [.withoutEscapingSlashes]
              ),
              let compactString = String(data: compactData, encoding: .utf8) else {
            return nil
        }
        return compactString
    }
}
