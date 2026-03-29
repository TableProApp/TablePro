//
//  StatusBar.swift
//  CodeEditTextViewExample
//
//  Created by Austin Condiff on 6/3/25.
//

import SwiftUI

struct StatusBar: View {
    @Environment(\.colorScheme)
    var colorScheme

    var text: NSTextStorage

    @Binding var wrapLines: Bool
    @Binding var enableEdgeInsets: Bool
    @Binding var useSystemCursor: Bool
    @Binding var isSelectable: Bool
    @Binding var isEditable: Bool

    var body: some View {
        HStack {
            Menu {
                Toggle("Wrap Lines", isOn: $wrapLines)
                Toggle("Inset Edges", isOn: $enableEdgeInsets)
                Toggle("Use System Cursor", isOn: $useSystemCursor)
                Toggle("Selectable", isOn: $isSelectable)
                Toggle("Editable", isOn: $isEditable)
            } label: {}
                .background {
                    Image(systemName: "switch.2")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13.5, weight: .regular))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: 18, alignment: .center)
            Spacer()
            Group {
                Text("\(text.length) characters")
            }
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .fontWeight(.medium)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) {
            VStack {
                Divider()
                    .overlay {
                        if colorScheme == .dark {
                            Color.black
                        }
                    }
            }
        }
        .zIndex(2)
    }
}
