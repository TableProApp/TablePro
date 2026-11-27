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
    /// How a parse of the pending edits ended.
    enum EditParseResult {
        /// The parsed state is committed; these ranges changed.
        case committed(IndexSet)
        /// A newer edit arrived first. Its parse applies these edits too.
        case superseded
        /// The budget ran out. The background parse for the same revision resumes it.
        case timedOut
        case cancelled
    }

    /// Parses every pending edit and commits the result, unless an edit arrived in the meantime.
    ///
    /// Reads the state, the edits and the text together, so the edits are exactly the ones between the state and
    /// the text. Commits with the same lock, so an edit landing after the read stops the commit. Neither step waits
    /// for the main thread.
    /// - Parameters:
    ///   - revision: The revision of the edit that asked for the parse.
    ///   - budget: How long each layer's parse may run before it stops; `nil` runs it to the end.
    func applyEdits(revision: Int, budget: TimeInterval?) -> EditParseResult {
        let interval = Self.signposter.beginInterval(
            "parse",
            id: Self.signposter.makeSignpostID(),
            "\(Self.threadName, privacy: .public)"
        )
        defer { Self.signposter.endInterval("parse", interval) }

        let (base, edits, text, current) = pipeline.withValue { ($0.state, $0.edits, $0.text, $0.revision) }
        guard current == revision else { return .superseded }
        guard let state = base?.copy(), let text else { return .committed(IndexSet()) }

        var invalidatedRanges = IndexSet()
        var touchedLayers = Set<LanguageLayer>()

        // Loop through all layers, apply edits & find changed byte ranges.
        for (idx, layer) in state.layers.enumerated().reversed() {
            if Task.isCancelled { return .cancelled }

            if layer.id != state.primaryLayer.id {
                applyEditTo(layer: layer, edits: edits)

                if layer.ranges.isEmpty {
                    state.removeLanguageLayer(at: idx)
                    continue
                }

                touchedLayers.insert(layer)
            }

            layer.parser.includedRanges = layer.ranges.map { $0.tsRange }
            switch layer.findChangedByteRanges(
                edits: edits,
                revision: revision,
                budget: budget,
                readBlock: text.readBlock
            ) {
            case .parsed(let ranges):
                invalidatedRanges.insert(ranges: ranges)
            case .timedOut:
                return .timedOut
            case .cancelled:
                return .cancelled
            }
        }

        if Task.isCancelled { return .cancelled }

        // Update the state object for any new injections that may have been caused by this edit.
        invalidatedRanges.formUnion(state.updateInjectedLayers(
            readCallback: text.readCallback,
            readBlock: text.readBlock,
            touchedLayers: touchedLayers
        ))

        if Task.isCancelled { return .cancelled }

        let replaced = pipeline.mutate { pipeline -> TreeSitterState?? in
            guard pipeline.revision == revision else { return .none }
            let replaced = pipeline.state
            pipeline.state = state
            pipeline.stateText = text
            pipeline.edits = []
            return .some(replaced)
        }
        guard let replaced else { return .superseded }
        Self.releaseOffMain(replaced)
        return .committed(invalidatedRanges)
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
