//
//  TreeSitterClient+Highlight.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 3/10/23.
//

import Foundation
import SwiftTreeSitter
import TableProGrammars

extension TreeSitterClient {
    func queryHighlightsForRange(range: NSRange) -> [HighlightRange] {
        let (state, text) = pipeline.withValue { ($0.state, $0.stateText) }
        guard let state, let text else { return [] }
        let readCallback = text.readCallback

        var highlights: [HighlightRange] = []
        var injectedSet = IndexSet(integersIn: range)

        for layer in state.layers where layer.id != state.primaryLayer.id {
            // Query injected only if a layer's ranges intersects with `range`
            for layerRange in layer.ranges {
                if let rangeIntersection = range.intersection(layerRange) {
                    let queryResult = queryLayerHighlights(
                        layer: layer,
                        range: rangeIntersection,
                        readCallback: readCallback
                    )

                    highlights.append(contentsOf: queryResult)
                    injectedSet.remove(integersIn: rangeIntersection)
                }
            }
        }

        // Query primary for any ranges that weren't used in the injected layers.
        for range in injectedSet.rangeView {
            let queryResult = queryLayerHighlights(
                layer: state.layers[0],
                range: NSRange(range),
                readCallback: readCallback
            )
            highlights.append(contentsOf: queryResult)
        }

        return highlights
    }

    /// Queries the given language layer for any highlights.
    /// - Parameters:
    ///   - layer: The layer to query.
    ///   - range: The range to query for.
    /// - Returns: Any ranges to highlight.
    internal func queryLayerHighlights(
        layer: LanguageLayer,
        range: NSRange,
        readCallback: @escaping SwiftTreeSitter.Predicate.TextProvider
    ) -> [HighlightRange] {
        guard let tree = layer.tree,
              let rootNode = tree.rootNode else {
            return []
        }

        guard let queryCursor = layer.languageQuery?.execute(node: rootNode, in: tree) else {
            return []
        }
        queryCursor.setRange(range)
        queryCursor.matchLimit = Constants.matchLimit

        return highlightsFromCursor(cursor: queryCursor, includedRange: range, readCallback: readCallback)
    }

    /// Resolves a query cursor to the highlight ranges it contains.
    /// - Parameters:
    ///     - cursor: The cursor to resolve.
    ///     - includedRange: The range to include highlights from.
    ///     - readCallback: Reads the text the cursor's tree was parsed from, for the query's predicates.
    /// - Returns: Any highlight ranges contained in the cursor.
    internal func highlightsFromCursor(
        cursor: QueryCursor,
        includedRange: NSRange,
        readCallback: @escaping SwiftTreeSitter.Predicate.TextProvider
    ) -> [HighlightRange] {
        var ranges: [NSRange: Int] = [:]
        return cursor
            .resolve(with: .init(textProvider: readCallback)) // Resolve our cursor against the query
            .flatMap { $0.captures }
            .reversed() // SwiftTreeSitter returns captures in the reverse order of what we need to filter with.
            .compactMap { capture in
                let range = capture.range
                let index = capture.index

                // Lower indexed captures are favored over higher, this is why we reverse it above
                if let existingLevel = ranges[range], existingLevel <= index {
                    return nil
                }

                guard let captureName = CaptureName.fromString(capture.name) else {
                    return nil
                }

                // Update the filter level to the current index since it's lower and a 'valid' capture
                ranges[range] = index

                // Validate range and capture name
                let intersectionRange = range.intersection(includedRange) ?? .zero
                guard intersectionRange.length > 0 else {
                    return nil
                }

                return HighlightRange(range: intersectionRange, capture: captureName)
            }
    }
}
