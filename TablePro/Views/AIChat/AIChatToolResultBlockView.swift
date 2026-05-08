//
//  AIChatToolResultBlockView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct AIChatToolResultBlockView: View {
    let block: ToolResultBlock

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: block.isError ? "xmark.circle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(accentColor)
                    Text(headerLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.borderless)

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(displayContent)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 8)
    }

    private var accentColor: Color {
        block.isError
            ? Color(nsColor: .systemRed)
            : Color(nsColor: .systemGreen)
    }

    private var headerLabel: String {
        block.isError
            ? String(localized: "Error")
            : String(localized: "Result")
    }

    private var displayContent: String {
        guard let data = block.content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              ),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: parsed,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return block.content
        }
        return pretty
    }
}
