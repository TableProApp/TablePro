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

    private var pairs: [DiffPair] {
        DiffComputer.computeSplit(before: targetLines, after: sourceLines)
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

            TextDiffView(
                pairs: pairs,
                beforeLabel: targetLabel,
                afterLabel: sourceLabel,
                layout: isUnified ? .unified : .split
            )
        }
    }
}
