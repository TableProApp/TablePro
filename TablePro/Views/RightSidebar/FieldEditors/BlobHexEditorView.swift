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

    private var readOnlyHexView: some View {
        ScrollView {
            Text(BlobFormattingService.shared.format(context.value.wrappedValue, for: .detail) ?? "")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: 120)
    }

    private var editableHexView: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Hex bytes", text: $hexEditText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(3...8)
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
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                if BlobFormattingService.shared.parseHex(hexEditText) == nil, !hexEditText.isEmpty {
                    Text("Invalid hex")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
            }
        }
    }

    private func commitHexEdit() {
        if let raw = BlobFormattingService.shared.parseHex(hexEditText) {
            context.value.wrappedValue = raw
        } else {
            hexEditText = BlobFormattingService.shared.format(context.value.wrappedValue, for: .edit) ?? ""
        }
    }
}
