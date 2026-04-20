//
//  HexEditorContentView.swift
//  TablePro
//
//  SwiftUI popover content for viewing and editing BLOB column values as hex.
//

import AppKit
import SwiftUI

struct HexEditorContentView: View {
    let initialValue: String?
    let onCommit: (String) -> Void
    let onDismiss: () -> Void

    @State private var hexDumpText: String
    @State private var editableHex: String
    @State private var isValid: Bool = true
    @State private var isTruncated: Bool = false
    @State private var byteCount: Int = 0
    @State private var validateWorkItem: DispatchWorkItem?

    init(
        initialValue: String?,
        onCommit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initialValue = initialValue
        self.onCommit = onCommit
        self.onDismiss = onDismiss

        let service = BlobFormattingService.shared
        if let value = initialValue, !value.isEmpty {
            let editHex = service.format(value, for: .edit) ?? ""
            let truncated = editHex.hasSuffix("…")
            self._hexDumpText = State(initialValue: service.format(value, for: .detail) ?? "")
            self._editableHex = State(initialValue: editHex)
            self._byteCount = State(initialValue: value.data(using: .isoLatin1)?.count ?? 0)
            self._isTruncated = State(initialValue: truncated)
            self._isValid = State(initialValue: !truncated)
        } else {
            self._hexDumpText = State(initialValue: "")
            self._editableHex = State(initialValue: "")
            self._byteCount = State(initialValue: 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HexDumpDisplayView(text: hexDumpText)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Editable Hex")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HexInputTextView(text: $editableHex)
                    .frame(height: 80)

                HStack(spacing: 4) {
                    Text("\(byteCount) bytes")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if isTruncated {
                        Text(String(localized: "Truncated — read only"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if !isValid, !editableHex.isEmpty {
                        Text(String(localized: "Invalid hex"))
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveHex() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isTruncated)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 520, height: 400)
        .onChange(of: editableHex) { _, newValue in
            scheduleValidation(newValue)
        }
    }

    // MARK: - Actions

    private func saveHex() {
        guard isValid else { return }

        if editableHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if initialValue != nil, initialValue != "" {
                onCommit("")
            }
            onDismiss()
            return
        }

        guard let rawValue = BlobFormattingService.shared.parseHex(editableHex) else { return }
        if rawValue != initialValue {
            onCommit(rawValue)
        }
        onDismiss()
    }

    private func scheduleValidation(_ hex: String) {
        validateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [hex] in
            validateHex(hex)
        }
        validateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private func validateHex(_ hex: String) {
        if hex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isValid = true
            isTruncated = false
            byteCount = 0
            hexDumpText = ""
            return
        }

        if hex.hasSuffix("…") {
            isTruncated = true
            isValid = false
            return
        }

        isTruncated = false
        if let parsed = BlobFormattingService.shared.parseHex(hex) {
            isValid = true
            byteCount = parsed.data(using: .isoLatin1)?.count ?? 0
            hexDumpText = parsed.formattedAsHexDump() ?? ""
        } else {
            isValid = false
            byteCount = 0
        }
    }
}

// MARK: - Hex Dump Display View (Read-Only)

private struct HexDumpDisplayView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(
            ofSize: 11,
            weight: .regular
        )
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.secondaryLabelColor
        textView.string = text

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}

// MARK: - Hex Input Text View (Editable)

private struct HexInputTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        )
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true

        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false

        textView.delegate = context.coordinator
        textView.string = text

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text, !context.coordinator.isUpdating {
            textView.string = text
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HexInputTextView
        var isUpdating = false

        init(_ parent: HexInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isUpdating = true
            parent.text = textView.string
            isUpdating = false
        }
    }
}
