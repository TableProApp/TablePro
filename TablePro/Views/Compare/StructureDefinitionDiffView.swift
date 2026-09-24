//
//  StructureDefinitionDiffView.swift
//  TablePro
//
//  Source and target definitions side by side. Both sides are rendered from
//  parsed metadata through the same function, so only real differences show.
//  Difference type carries a glyph as well as a colour.
//

import SwiftUI

internal struct StructureDefinitionDiffView: View {
    internal var title = String(localized: "Definition")
    internal var sourceLabel = String(localized: "Source")
    internal var targetLabel = String(localized: "Target")
    internal let sourceLines: [String]
    internal let targetLines: [String]

    @State private var isUnified = false
    @State private var presentation: StructureDefinitionDiffPresentation?

    private var input: StructureDefinitionDiffInput {
        StructureDefinitionDiffInput(sourceLines: sourceLines, targetLines: targetLines)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("", selection: $isUnified) {
                    Text("Split").tag(false)
                    Text("Unified").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.bottom, 6)

            diffBody
        }
        .task(id: input) {
            let loaded = await StructureDefinitionDiffPresentation.load(input)
            guard !Task.isCancelled else { return }
            presentation = loaded
        }
    }

    @ViewBuilder
    private var diffBody: some View {
        if let presentation, presentation.isCurrent(for: input) {
            TextDiffView(
                pairs: presentation.pairs,
                beforeLabel: targetLabel,
                afterLabel: sourceLabel,
                layout: isUnified ? .unified : .split
            )
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}
