//
//  BlobHexEditorView.swift
//  TablePro
//

import SwiftUI

internal struct BlobHexEditorView: View {
    let context: FieldEditorContext

    @FocusState private var isFocused: Bool
    @State private var hexEditText = ""

    /// The editable form stops at 10,240 bytes and marks the cut with a trailing ellipsis, so what
    /// the field holds is a prefix rather than the value. Committing it would write that prefix over
    /// the whole column: measured, a 50,000-byte value came back as 10,240, losing 39,760 bytes with
    /// the save reporting success. The pop-out editor has always refused this; the inline one read
    /// the same marker as a syntax error, so it reported "Invalid hex" over an untouched value and
    /// then silently reverted every edit on blur.
    ///
    /// Recorded from the stored value when the draft is loaded, never asked of `hexEditText`, which
    /// is the user's to type into: reading the marker off the draft let an ordinary blob well under
    /// the limit be locked for good by pasting an ellipsis into it. It is cached rather than
    /// computed per read because the formatter materializes the whole backing string before it
    /// takes its 10,240-byte prefix, and a computed property pays that on every body pass, twice.
    @State private var isTruncated = false

    var body: some View {
        if context.isReadOnly {
            readOnlyHexView
        } else {
            editableHexView
        }
    }

    /// A dump line is wider than the inspector at any font, so it scrolls in both axes. Letting it
    /// wrap to the pane instead folds each line onto the next and the offset, hex and ASCII columns
    /// stop lining up, which is the whole point of a dump.
    ///
    /// It names the value font rather than inheriting one for the same reason. The row supplies that
    /// font only for `.blobHex`; reached through `.image`, which opts out of the value-font domain,
    /// this identical view drew in the proportional system face and its columns stopped lining up.
    private var readOnlyHexView: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(BlobFormattingService.shared.format(context.value.wrappedValue, for: .detail) ?? "")
                .font(ThemeEngine.shared.valueFontSwiftUI)
                .textSelection(.enabled)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: 120)
    }

    /// A value past the cap shows the dump it can show, selectable, rather than a disabled field.
    /// A disabled `TextField` on macOS cannot take first responder or have its text selected, so
    /// gating the editor that way took the value away from the keyboard and the pasteboard both,
    /// while `InspectorFieldListView.moveFocus` went on stopping at the row.
    private var editableHexView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isTruncated {
                readOnlyHexView
            } else {
                TextField("Hex bytes", text: $hexEditText, axis: .vertical)
                    .font(ThemeEngine.shared.valueFontSwiftUI)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...8)
                    .autocorrectionDisabled(true)
                    .focused($isFocused)
                    .onChange(of: isFocused) {
                        if !isFocused {
                            commitHexEdit()
                        }
                    }
            }

            statusLine
        }
        .onAppear { loadDraft() }
        .onChange(of: context.value.wrappedValue) {
            if !isFocused {
                loadDraft()
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            if let byteCount = context.value.wrappedValue.data(using: .isoLatin1)?.count, byteCount > 0 {
                Text("\(byteCount) bytes")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if isTruncated {
                Text("Truncated, read only")
                    .font(.caption2)
                    .foregroundStyle(ThemeEngine.shared.palette.color(.statusWarning))
            } else if BlobFormattingService.shared.parseHex(hexEditText) == nil, !hexEditText.isEmpty {
                Text("Invalid hex")
                    .font(.caption2)
                    .foregroundStyle(ThemeEngine.shared.palette.color(.statusError))
            }
        }
    }

    /// One place that formats the stored value for editing, so the draft and the truncation flag
    /// are always taken from the same read rather than from two.
    private func loadDraft() {
        let formatted = BlobFormattingService.shared.format(context.value.wrappedValue, for: .edit) ?? ""
        hexEditText = formatted
        isTruncated = formatted.hasSuffix("…")
    }

    private func commitHexEdit() {
        guard !isTruncated else { return }
        guard let raw = BlobFormattingService.shared.parseHex(hexEditText) else {
            loadDraft()
            return
        }
        if let commitBytes = context.commitBytes,
           let data = raw.data(using: .isoLatin1) {
            commitBytes(data)
        } else {
            context.value.wrappedValue = raw
        }
    }
}
