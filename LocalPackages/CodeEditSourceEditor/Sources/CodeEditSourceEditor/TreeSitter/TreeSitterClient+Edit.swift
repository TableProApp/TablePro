//
//  TreeSitterClient+Edit.swift
//  
//
//  Created by Khan Winter on 3/10/23.
//

import Foundation
import SwiftTreeSitter
import CodeEditLanguages

extension TreeSitterClient {
    /// Applies the given edit to the current state and calls the editState's completion handler.
    ///
    /// Concurrency note: This method checks for task cancellation between layer edits, after editing all layers, and
    /// before setting the client's state.
    ///
    /// - Parameter edit: The edit to apply to the internal tree sitter state.
    /// - Returns: The set of ranges invalidated by the edit operation.
    func applyEdit(edit: InputEdit) -> IndexSet {
        guard let state = state?.copy(), let readBlock, let readCallback else { return IndexSet() }
        let pendingEdits = pendingEdits.value() // Grab pending edits.
        let edits = pendingEdits + [edit]

        var invalidatedRanges = IndexSet()
        var touchedLayers = Set<LanguageLayer>()

        // Loop through all layers, apply edits & find changed byte ranges.
        for (idx, layer) in state.layers.enumerated().reversed() {
            if Task.isCancelled { return IndexSet() }

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

        if Task.isCancelled { return IndexSet() }

        // Update the state object for any new injections that may have been caused by this edit.
        invalidatedRanges.formUnion(state.updateInjectedLayers(
            readCallback: readCallback,
            readBlock: readBlock,
            touchedLayers: touchedLayers
        ))

        if Task.isCancelled { return IndexSet() }

        self.state = state // Apply the copied state
        self.pendingEdits.mutate { edits in // Clear the queue
            edits = []
        }

        return invalidatedRanges
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
