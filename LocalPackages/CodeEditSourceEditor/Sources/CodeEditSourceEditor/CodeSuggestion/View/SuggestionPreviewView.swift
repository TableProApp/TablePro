//
//  SuggestionPreviewView.swift
//  CodeEditSourceEditor
//
//  Created by Claude on 2026-03-19.
//

import AppKit
import SwiftUI

struct SuggestionPreviewView: View {
    let item: CodeSuggestionEntry
    let syntaxHighlight: NSAttributedString?
    let font: NSFont

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let highlighted = syntaxHighlight {
                Text(AttributedString(highlighted))
                    .textSelection(.enabled)
            }
            if let doc = item.documentation {
                Text(doc)
                    .font(Font(font))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let components = item.pathComponents, !components.isEmpty {
                pathBreadcrumb(components)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pathBreadcrumb(_ components: [String]) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .font(.system(size: font.pointSize - 2))
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: font.pointSize - 4))
                }
                Text(component)
                    .font(Font(font))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let pos = item.targetPosition {
                Text(":\(pos.start.line):\(pos.start.column)")
                    .font(Font(font))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
