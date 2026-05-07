//
//  AIChatToolUseBlockView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct AIChatToolUseBlockView: View {
    let block: ToolUseBlock

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasInput else { return }
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.adjustable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(String(localized: "Calling"))
                            .foregroundStyle(.secondary)
                        Text(block.name)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                    }
                    .font(.caption)
                    if hasInput {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            if isExpanded && hasInput {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(prettyInput)
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

    private var hasInput: Bool {
        switch block.input {
        case .object(let dict): return !dict.isEmpty
        case .array(let array): return !array.isEmpty
        case .null: return false
        default: return true
        }
    }

    private var prettyInput: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(block.input),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}
