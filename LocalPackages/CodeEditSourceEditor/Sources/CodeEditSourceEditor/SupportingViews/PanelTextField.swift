//
//  PanelTextField.swift
//  CodeEdit
//
//  Created by Austin Condiff on 11/2/23.
//

import SwiftUI
import Combine

struct PanelTextField<LeadingAccessories: View, TrailingAccessories: View>: View {
    @Environment(\.colorScheme)
    var colorScheme

    @Environment(\.controlActiveState)
    private var controlActive

    @FocusState private var isFocused: Bool

    var label: String

    @Binding private var text: String

    let axis: Axis

    let leadingAccessories: LeadingAccessories?

    let trailingAccessories: TrailingAccessories?

    let helperText: String?

    var clearable: Bool

    var onClear: (() -> Void)

    init(
        _ label: String,
        text: Binding<String>,
        axis: Axis? = .horizontal,
        @ViewBuilder leadingAccessories: () -> LeadingAccessories? = { EmptyView() },
        @ViewBuilder trailingAccessories: () -> TrailingAccessories? = { EmptyView() },
        helperText: String? = nil,
        clearable: Bool? = false,
        onClear: (() -> Void)? = {}
    ) {
        self.label = label
        _text = text
        self.axis = axis ?? .horizontal
        self.leadingAccessories = leadingAccessories()
        self.trailingAccessories = trailingAccessories()
        self.helperText = helperText ?? nil
        self.clearable = clearable ?? false
        self.onClear = onClear ?? {}
    }

    @ViewBuilder
    public func selectionBackground(
        _ isFocused: Bool = false
    ) -> some View {
        if self.controlActive != .inactive || !text.isEmpty {
            if isFocused || !text.isEmpty {
                Color(.textBackgroundColor)
            } else {
                if colorScheme == .light {
                    // TODO: if over sidebar 0.06 else 0.085
//                    Color.black.opacity(0.06)
                    Color.black.opacity(0.085)
                } else {
                    // TODO: if over sidebar 0.24 else 0.06
//                    Color.white.opacity(0.24)
                    Color.white.opacity(0.06)
                }
            }
        } else {
            if colorScheme == .light {
                // TODO: if over sidebar 0.0 else 0.06
//                Color.clear
                Color.black.opacity(0.06)
            } else {
                // TODO: if over sidebar 0.14 else 0.045
//                Color.white.opacity(0.14)
                Color.white.opacity(0.045)
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let leading = leadingAccessories {
                leading
                    .frame(height: 20)
            }
            HStack {
                TextField(label, text: $text, axis: axis)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .controlSize(.small)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .foregroundStyle(.primary)
                if let helperText {
                    Text(helperText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if clearable == true {
                Button {
                    self.text = ""
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.icon(font: .system(size: 11, weight: .semibold), size: CGSize(width: 20, height: 20)))
                .opacity(text.isEmpty ? 0 : 1)
                .disabled(text.isEmpty)
            }
            if let trailing = trailingAccessories {
                trailing
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .buttonStyle(.icon(font: .system(size: 11, weight: .semibold), size: CGSize(width: 28, height: 20)))
        .toggleStyle(.icon(font: .system(size: 11, weight: .semibold), size: CGSize(width: 28, height: 20)))
        .frame(minHeight: 22)
        .background(
            selectionBackground(isFocused)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .edgesIgnoringSafeArea(.all)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused || !text.isEmpty ? .tertiary : .quaternary, lineWidth: 1.25)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(true)
                .edgesIgnoringSafeArea(.all)
        )

        .onTapGesture {
            isFocused = true
        }
    }
}
