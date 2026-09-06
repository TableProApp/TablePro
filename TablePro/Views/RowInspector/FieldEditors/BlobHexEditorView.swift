//
//  BlobHexEditorView.swift
//  TablePro
//

import SwiftUI

internal struct BlobHexEditorView: View {
    let context: FieldEditorContext

    @FocusState private var isFocused: Bool
    @State private var hexEditText = ""

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
    private var readOnlyHexView: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(BlobFormattingService.shared.format(context.value.wrappedValue, for: .detail) ?? "")
                .textSelection(.enabled)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: 120)
    }

    private var editableHexView: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Hex bytes", text: $hexEditText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
                .autocorrectionDisabled(true)
                .focused($isFocused)
                .onAppear {
                    hexEditText = BlobFormattingService.shared.format(context.value.wrappedValue, for: .edit) ?? ""
                }
                .onChange(of: context.value.wrappedValue) {
                    if !isFocused {
                        hexEditText = BlobFormattingService.shared.format(context.value.wrappedValue, for: .edit) ?? ""
                    }
                }
                .onChange(of: isFocused) {
                    if !isFocused {
                        commitHexEdit()
                    }
                }

            HStack(spacing: 4) {
                if let byteCount = context.value.wrappedValue.data(using: .isoLatin1)?.count, byteCount > 0 {
                    Text("\(byteCount) bytes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if BlobFormattingService.shared.parseHex(hexEditText) == nil, !hexEditText.isEmpty {
                    Text("Invalid hex")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func commitHexEdit() {
        guard let raw = BlobFormattingService.shared.parseHex(hexEditText) else {
            hexEditText = BlobFormattingService.shared.format(context.value.wrappedValue, for: .edit) ?? ""
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
