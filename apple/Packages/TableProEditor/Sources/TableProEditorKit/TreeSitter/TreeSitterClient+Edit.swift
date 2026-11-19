//
//  TreeSitterClient+Edit.swift
//  
//
//  Created by Khan Winter on 3/10/23.
//

import Foundation
import SwiftTreeSitter
import TableProGrammars

extension TreeSitterClient {
    // Nil when the edits were abandoned: they stay on `pendingEdits` for the parse that superseded this one.
    func applyEdits(
        _ edits: [InputEdit],
        revision: Int,
        readBlock: Parser.ReadBlock?,
        readCallback: SwiftTreeSitter.Predicate.TextProvider?
    ) -> IndexSet? {
        guard let state = state?.copy(), let readBlock, let readCallback else { return IndexSet() }

        var invalidatedRanges = IndexSet()
        var touchedLayers = Set<LanguageLayer>()

        // Loop through all layers, apply edits & find changed byte ranges.
        for (idx, layer) in state.layers.enumerated().reversed() {
            if Task.isCancelled { return nil }

            if layer.id != state.primaryLayer.id {
                applyEditTo(layer: layer, edits: edits)

                if layer.ranges.isEmpty {
                    state.removeLanguageLayer(at: idx)
                    continue
                }

                touchedLayers.insert(layer)
            }

            layer.parser.includedRanges = layer.ranges.map { $0.tsRange }
            let ranges = layer.findChangedByteRanges(
                edits: edits,
                timeout: Constants.parserTimeout,
                readBlock: readBlock
            )
            invalidatedRanges.insert(ranges: ranges)
        }

        if Task.isCancelled { return nil }

        // Update the state object for any new injections that may have been caused by this edit.
        invalidatedRanges.formUnion(state.updateInjectedLayers(
            readCallback: readCallback,
            readBlock: readBlock,
            touchedLayers: touchedLayers
        ))

        if Task.isCancelled { return nil }

        return DispatchQueue.waitMainIfNot {
            guard editRevision == revision else { return nil }
            self.state = state
            pendingEdits.mutate { edits in
                edits = []
            }
            return invalidatedRanges
        }
    }

    private func applyEditTo(layer: LanguageLayer, edits: [InputEdit]) {
        // Reversed for safe removal while looping
        for rangeIdx in (0..<layer.ranges.count).reversed() {
            for edit in edits {
                layer.ranges[rangeIdx].applyInputEdit(edit)
            }

            if layer.ranges[rangeIdx].length <= 0 {
                layer.ranges.remove(at: rangeIdx)
            }
        }
    }
}
