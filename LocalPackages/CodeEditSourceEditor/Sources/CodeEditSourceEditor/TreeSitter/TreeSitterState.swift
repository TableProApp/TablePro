//
//  TreeSitterState.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/21/23.
//

import Foundation
import SwiftTreeSitter
import CodeEditLanguages

/// TreeSitterState contains the tree of language layers that make up the tree-sitter document.
public final class TreeSitterState {
    private(set) var primaryLayer: CodeLanguage
    private(set) var layers: [LanguageLayer] = []

    // MARK: - Init

    /// Initialize a state object with a language and text view.
    /// - Parameters:
    ///   - codeLanguage: The language to use.
    ///   - readCallback: Callback used to read text for a specific range.
    ///   - readBlock: Callback used to read blocks of text.
    init(
        codeLanguage: CodeLanguage,
        readCallback: @escaping SwiftTreeSitter.Predicate.TextProvider,
        readBlock: @escaping Parser.ReadBlock
    ) {
        self.primaryLayer = codeLanguage
        self.setLanguage(codeLanguage)
        self.parseDocument(readCallback: readCallback, readBlock: readBlock)
    }

    /// Private initializer used by `copy`
    private init(codeLanguage: CodeLanguage, layers: [LanguageLayer]) {
        self.primaryLayer = codeLanguage
        self.layers = layers
    }

    /// Creates a copy of the current state.
    ///
    /// This should be a fairly cheap operation. Copying tree-sitter trees never actually copies the contents, just
    /// increments a global ref counter.
    ///
    /// - Returns: A new, disconnected copy of the tree sitter state.
    public func copy() -> TreeSitterState {
        TreeSitterState(codeLanguage: primaryLayer, layers: layers.map { $0.copy() })
    }

    /// Sets the language for the state. Removing all existing layers.
    /// - Parameter codeLanguage: The language to use.
    private func setLanguage(_ codeLanguage: CodeLanguage) {
        layers.removeAll()

        primaryLayer = codeLanguage
        layers = [
            LanguageLayer(
                id: codeLanguage.id,
                tsLanguage: codeLanguage.language,
                parser: Parser(),
                supportsInjections: codeLanguage.additionalHighlights?.contains("injections") ?? false,
                tree: nil,
                languageQuery: TreeSitterModel.shared.query(for: codeLanguage.id),
                ranges: []
            )
        ]

        guard let treeSitterLanguage = codeLanguage.language else { return }
        try? layers[0].parser.setLanguage(treeSitterLanguage)
    }

    /// Performs the initial document parse for the primary layer.
    /// - Parameters:
    ///   - readCallback: The callback to use to read content from the document.
    ///   - readBlock: The callback to use to read blocks of content from the document.
    private func parseDocument(
        readCallback: @escaping SwiftTreeSitter.Predicate.TextProvider,
        readBlock: @escaping Parser.ReadBlock
    ) {
        layers[0].parser.timeout = 0.0
        layers[0].tree = layers[0].parser.parse(tree: nil as Tree?, readBlock: readBlock)

        var layerSet = Set<LanguageLayer>(arrayLiteral: layers[0])
        var touchedLayers = Set<LanguageLayer>()

        var idx = 0
        while idx < layers.count {
            updateInjectedLanguageLayer(
                readCallback: readCallback,
                readBlock: readBlock,
                layer: layers[idx],
                layerSet: &layerSet,
                touchedLayers: &touchedLayers
            )

            idx += 1
        }
    }

    // MARK: - Layer Management

    /// Removes a layer at the given index.
    /// - Parameter idx: The index of the layer to remove.
    public func removeLanguageLayer(at idx: Int) {
        layers.remove(at: idx)
    }

    /// Removes all languagel ayers in the given set.
    /// - Parameter set: A set of all language layers to remove.
    public func removeLanguageLayers(in set: Set<LanguageLayer>) {
        layers.removeAll(where: { set.contains($0) })
    }

    /// Attempts to create a language layer and load a highlights file.
    /// Adds the layer to the `layers` array if successful.
    /// - Parameters:
    ///   - layerId: A language ID to add as a layer.
    ///   - readBlock: Completion called for efficient string lookup.
    public func addLanguageLayer(
        layerId: TreeSitterLanguage,
        readBlock: @escaping Parser.ReadBlock
    ) -> LanguageLayer? {
        guard let language = CodeLanguage.allLanguages.first(where: { $0.id == layerId }),
              let parserLanguage = language.language
        else {
            return nil
        }

        let newLayer = LanguageLayer(
            id: layerId,
            tsLanguage: language.language,
            parser: Parser(),
            supportsInjections: language.additionalHighlights?.contains("injections") ?? false,
            tree: nil,
            languageQuery: TreeSitterModel.shared.query(for: layerId),
            ranges: []
        )

        do {
            try newLayer.parser.setLanguage(parserLanguage)
        } catch {
            return nil
        }

        layers.append(newLayer)
        return newLayer
    }

    // MARK: - Injection Layers

    /// Inserts any new language layers, and removes any that may have been deleted after an edit.
    /// - Parameters:
    ///   - readCallback: Callback used to read text for a specific range.
    ///   - readBlock: Callback used to read blocks of text.
    ///   - touchedLayers: A set of layers. Each time a layer is visited, it will be removed from this set.
    ///                    Use this to determine if any layers were not modified after this method was run.
    ///                    Those layers should be removed.
    /// - Returns: A set of indices of any new layers. This set indicates ranges that should be re-highlighted.
    public func updateInjectedLayers(
        readCallback: @escaping SwiftTreeSitter.Predicate.TextProvider,
        readBlock: @escaping Parser.ReadBlock,
        touchedLayers: Set<LanguageLayer>
    ) -> IndexSet {
        var layerSet = Set(layers)
        var touchedLayers = touchedLayers
        var rangeSet = IndexSet()

        // Loop through each layer and apply injections query, add any ranges not previously found
        // using while loop because `updateInjectedLanguageLayer` can add to `layers` during the loop
        var idx = 0
        while idx < layers.count {
            let layer = layers[idx]

            if layer.supportsInjections {
                rangeSet.formUnion(
                    updateInjectedLanguageLayer(
                        readCallback: readCallback,
                        readBlock: readBlock,
                        layer: layer,
                        layerSet: &layerSet,
                        touchedLayers: &touchedLayers
                    )
                )
            }

            idx += 1
        }

        // Delete any layers that weren't touched at some point during the edit.
        removeLanguageLayers(in: touchedLayers)

        return rangeSet
    }

    /// Performs an injections query on the given language layer.
    /// Updates any existing layers with new ranges and adds new layers if needed.
    /// - Parameters:
    ///   - readCallback: Callback used to read text for a specific range.
    ///   - readBlock: Callback used to read blocks of text.
    ///   - layer: The language layer to perform the query on.
    ///   - layerSet: The set of layers that exist in the document.
    ///               Used for efficient lookup of existing `(language, range)` pairs
    ///   - touchedLayers: The set of layers that existed before updating injected layers.
    ///                    Will have items removed as they are found.
    /// - Returns: An index set of any updated indexes.
    @discardableResult
    private func updateInjectedLanguageLayer(
        readCallback: @escaping SwiftTreeSitter.Predicate.TextProvider,
        readBlock: @escaping Parser.ReadBlock,
        layer: LanguageLayer,
        layerSet: inout Set<LanguageLayer>,
        touchedLayers: inout Set<LanguageLayer>
    ) -> IndexSet {
        guard let tree = layer.tree,
              let rootNode = tree.rootNode,
              let cursor = layer.languageQuery?.execute(node: rootNode, in: tree) else {
            return IndexSet()
        }

        cursor.matchLimit = TreeSitterClient.Constants.matchLimit

        let languageRanges = self.injectedLanguagesFrom(cursor: cursor) { range, point in
            return readCallback(range, point)
        }

        var updatedRanges = IndexSet()

        for (languageName, ranges) in languageRanges {
            guard let treeSitterLanguage = TreeSitterLanguage(rawValue: languageName) else {
                continue
            }

            if treeSitterLanguage == primaryLayer.id {
                continue
            }

            for range in ranges {
                // Temp layer object
                let layer = LanguageLayer(
                    id: treeSitterLanguage,
                    tsLanguage: nil,
                    parser: Parser(),
                    supportsInjections: false,
                    ranges: [range.range]
                )

                if layerSet.contains(layer) {
                    // If we've found this layer, it means it should exist after an edit.
                    touchedLayers.remove(layer)
                } else {
                    // New range, make a new layer!
                    if let addedLayer = addLanguageLayer(layerId: treeSitterLanguage, readBlock: readBlock) {
                        addedLayer.ranges = [range.range]
                        addedLayer.parser.includedRanges = addedLayer.ranges.map { $0.tsRange }
                        addedLayer.tree = addedLayer.parser.parse(tree: nil as Tree?, readBlock: readBlock)

                        layerSet.insert(addedLayer)
                        updatedRanges.insert(range: range.range)
                    }
                }
            }
        }

        return updatedRanges
    }

    /// Returns all injected languages from a given cursor. The cursor must be new,
    /// having not been used for normal highlight matching.
    /// - Parameters:
    ///   - cursor: The cursor to use for finding injected languages.
    ///   - textProvider: A callback for efficiently fetching text.
    /// - Returns: A map of each language to all the ranges they have been injected into.
    private func injectedLanguagesFrom(
        cursor: QueryCursor,
        textProvider: @escaping SwiftTreeSitter.Predicate.TextProvider
    ) -> [String: [NamedRange]] {
        var languages: [String: [NamedRange]] = [:]

        for match in cursor {
            if let injection = match.injection(with: textProvider) {
                if languages[injection.name] == nil {
                    languages[injection.name] = []
                }
                languages[injection.name]?.append(injection)
            }
        }

        return languages
    }
}
