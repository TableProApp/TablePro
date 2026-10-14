//
//  AIChatToolResultBlockView.swift
//  TablePro
//

import SwiftUI

struct AIChatToolResultBlockView: View {
    let block: ToolResultBlock

    @State private var isExpanded: Bool = false

    internal static let contentFont = Font.system(.caption, design: .monospaced)

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
                CodeWell(displayContent, font: Self.contentFont)
            }
        }
        .padding(.horizontal, 8)
    }

    private var accentColor: Color {
        block.isError
            ? .red
            : .green
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
