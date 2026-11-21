//
//  Highlighter.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 9/12/22.
//

import AppKit
import Foundation
import OSLog
import SwiftTreeSitter
import TableProGrammars
import TableProTextEngine

public enum EditorHighlighting {
    // In UTF-16 units. Past it the per-edit parse and restyle cost dominates, so the document shows as plain text.
    public static let maxHighlightableCharacters = 2_000_000
}

/// This class manages fetching syntax highlights from providers, and applying those styles to the editor.
/// Multiple highlight providers can be used to style the editor.
///
/// This class manages multiple objects that help perform this task:
/// - ``StyledRangeContainer``
/// - ``RangeStore``
/// - ``VisibleRangeProvider``
/// - ``HighlightProviderState``
///
/// A hierarchal overview of the highlighter system.
/// ```
/// +---------------------------------+
/// |          Highlighter            |
/// |                                 |
/// |  - highlightProviders[]         |
/// |  - styledRangeContainer         |
/// |                                 |
/// |  + refreshHighlightsIn(range:)  |
/// +---------------------------------+
/// |
/// | Queries coalesced styles
/// v
/// +-------------------------------+             +-------------------------+
/// |    StyledRangeContainer       |   ------>   |      RangeStore[]       |
/// |                               |             |                         | Stores styles for one provider
/// |  - manages combined ranges    |             |  - stores raw ranges &  |
/// |  - layers highlight styles    |             |    captures             |
/// |  + getAttributesForRange()    |             +-------------------------+
/// +-------------------------------+
/// ^
/// | Sends highlighted runs
/// |
/// +-------------------------------+
/// |   HighlightProviderState[]    |   (one for each provider)
/// |                               |
/// |  - keeps valid/invalid ranges |
/// |  - queries providers (async)  |
/// |  + updateStyledRanges()       |
/// +-------------------------------+
/// ^
/// | Performs edits and sends highlight deltas, as well as calculates syntax captures for ranges
/// |
/// +-------------------------------+
/// |   HighlightProviding Object   |  (tree-sitter, LSP, spellcheck)
/// +-------------------------------+
/// ```
///
@MainActor
class Highlighter: NSObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "Highlighter")

    /// The current language of the editor.
    private var language: CodeLanguage

    /// The text view to highlight
    private weak var textView: TextView?

    /// The object providing attributes for captures.
    private weak var attributeProvider: ThemeAttributesProviding?

    private var styleContainer: StyledRangeContainer

    private var highlightProviders: [HighlightProviderState] = []

    private var visibleRangeProvider: VisibleRangeProvider

    /// Counts upwards to provide unique IDs for new highlight providers.
    private var providerIdCounter: Int

    let maxHighlightableLength: Int

    // The providers hear of no edit while the document is over the limit, so coming back under sets them up again.
    private var isWithinLimit: Bool

    // MARK: - Init

    init(
        textView: TextView,
        providers: [HighlightProviding],
        attributeProvider: ThemeAttributesProviding,
        language: CodeLanguage,
        maxHighlightableLength: Int = EditorHighlighting.maxHighlightableCharacters
    ) {
        self.language = language
        self.textView = textView
        self.attributeProvider = attributeProvider
        self.maxHighlightableLength = maxHighlightableLength
        self.isWithinLimit = textView.length <= maxHighlightableLength

        self.visibleRangeProvider = VisibleRangeProvider(textView: textView)

        let providerIds = providers.indices.map({ $0 })
        self.styleContainer = StyledRangeContainer(documentLength: textView.length, providers: providerIds)

        self.providerIdCounter = providers.count

        super.init()

        styleContainer.delegate = self
        visibleRangeProvider.delegate = self
        self.highlightProviders = providers.enumerated().map { idx, provider in
            HighlightProviderState(
                id: providerIds[idx],
                delegate: styleContainer,
                highlightProvider: provider,
                textView: textView,
                visibleRangeProvider: visibleRangeProvider,
                language: language
            )
        }
    }

    // MARK: - Public

    func invalidate() {
        guard isWithinLimit else { return }
        highlightProviders.forEach { $0.invalidate() }
    }

    /// A theme change moves no capture, so the captures already found are styled again in place. Asking the providers
    /// again would leave the text unstyled until they answer.
    func restyle() {
        guard let textView else { return }
        styleContainerDidUpdate(in: NSRange(location: 0, length: textView.textStorage.length))
    }

    func invalidate(_ set: IndexSet) {
        guard isWithinLimit else { return }
        highlightProviders.forEach { $0.invalidate(set) }
    }

    func setLanguage(language: CodeLanguage) {
        guard let textView = self.textView else { return }
        self.language = language

        // Remove all current highlights. Makes the language setting feel snappier and tells the user we're doing
        // something immediately.
        removeStyles(from: textView)

        guard isWithinLimit else { return }
        highlightProviders.forEach { $0.setLanguage(language: language) }
    }

    private func removeStyles(from textView: TextView) {
        let documentRange = NSRange(location: 0, length: textView.textStorage.length)
        textView.textStorage.setAttributes(attributeProvider?.attributesFor(nil) ?? [:], range: documentRange)
        textView.layoutManager.invalidateLayoutForRange(documentRange)
    }

    private func stopHighlighting() {
        isWithinLimit = false
        guard let textView else { return }
        styleContainer.reset(documentLength: textView.textStorage.length)
        removeStyles(from: textView)
    }

    private func resumeHighlighting() {
        isWithinLimit = true
        guard let textView else { return }
        styleContainer.reset(documentLength: textView.textStorage.length)
        highlightProviders.forEach { $0.setLanguage(language: language) }
        visibleRangeProvider.visibleTextChanged()
    }

    /// Updates the highlight providers the highlighter is using, removing any that don't appear in the given array,
    /// and setting up any new ones.
    ///
    /// This is essential for working with SwiftUI, as we'd like to allow highlight providers to be added and removed
    /// after the view is initialized. For instance after some sort of async registration method.
    ///
    /// - Note: Each provider will be identified by it's object ID.
    /// - Parameter providers: All providers to use.
    func setProviders(_ providers: [HighlightProviding]) {
        guard let textView else { return }
        self.styleContainer.updateStorageLength(newLength: textView.textStorage.length)

        let existingIds: [ObjectIdentifier] = self.highlightProviders
            .compactMap { $0.highlightProvider }
            .map { ObjectIdentifier($0) }
        let newIds: [ObjectIdentifier] = providers.map { ObjectIdentifier($0) }
        // 2nd param is what we're moving *from*. We want to find how we to make existingIDs equal newIDs
        let difference = newIds.difference(from: existingIds).inferringMoves()

        var highlightProviders = self.highlightProviders // Make a mutable copy
        var moveMap: [Int: (Int, HighlightProviderState)] = [:]

        for change in difference {
            switch change {
            case let .insert(offset, element, associatedOffset):
                guard associatedOffset == nil,
                      let newProvider = providers.first(where: { ObjectIdentifier($0) == element }) else {
                    // Moved, grab the moved object from the move map
                    guard let movedProvider = moveMap[offset] else {
                        continue
                    }
                    highlightProviders.insert(movedProvider.1, at: offset)
                    styleContainer.setPriority(providerId: movedProvider.0, priority: offset)
                    continue
                }
                // Set up a new provider and insert it with a unique ID
                providerIdCounter += 1
                let state = HighlightProviderState( // This will call setup on the highlight provider
                    id: providerIdCounter,
                    delegate: styleContainer,
                    highlightProvider: newProvider,
                    textView: textView,
                    visibleRangeProvider: visibleRangeProvider,
                    language: language
                )
                highlightProviders.insert(state, at: offset)
                styleContainer.addProvider(providerIdCounter, priority: offset, documentLength: textView.length)
                if isWithinLimit {
                    state.invalidate()
                }
            case let .remove(offset, _, associatedOffset):
                if let associatedOffset {
                    // Moved, add it to the move map
                    moveMap[associatedOffset] = (offset, highlightProviders.remove(at: offset))
                    continue
                }
                // Removed entirely
                styleContainer.removeProvider(highlightProviders.remove(at: offset).id)
            }
        }

        self.highlightProviders = highlightProviders
    }

    deinit {
        self.attributeProvider = nil
        self.textView = nil
        self.highlightProviders = []
    }
}

// MARK: NSTextStorageDelegate

extension Highlighter: @preconcurrency NSTextStorageDelegate {
    /// Processes an edited range in the text.
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // This method is called whenever attributes are updated, so to avoid re-highlighting the entire document
        // each time an attribute is applied, we check to make sure this is in response to an edit.
        guard editedMask.contains(.editedCharacters) else { return }
        guard textStorage.length <= maxHighlightableLength else {
            if isWithinLimit {
                stopHighlighting()
            }
            return
        }
        guard isWithinLimit else {
            resumeHighlighting()
            return
        }

        styleContainer.storageUpdated(editedRange: editedRange, changeInLength: delta)

        if delta > 0 {
            visibleRangeProvider.visibleSet.insert(range: editedRange)
        }

        visibleRangeProvider.visibleTextChanged()

        let providerRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        highlightProviders.forEach { $0.storageDidUpdate(range: providerRange, delta: delta) }
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        highlightProviders.forEach { $0.storageWillUpdate(in: editedRange) }
    }
}

// MARK: - StyledRangeContainerDelegate

extension Highlighter: StyledRangeContainerDelegate {
    func styleContainerDidUpdate(in range: NSRange) {
        // A provider can still answer for an edit made before the document went over the limit.
        guard isWithinLimit, let textView, let attributeProvider else { return }
        textView.textStorage.beginEditing()

        let storage = textView.textStorage

        // The style runs are tracked against the storage's length as of the last edit, so a run can
        // still name text that a newer edit removed. `setAttributes` raises for that rather than
        // ignoring it, and this runs inside an editing transaction on the storage.
        let storageLength = storage?.length ?? 0
        var offset = range.location
        for run in styleContainer.runsIn(range: range) {
            guard let runRange = NSRange(location: offset, length: run.length).intersection(range) else {
                continue
            }
            offset += runRange.length
            guard let styledRange = runRange.resolved(inDocumentOfLength: storageLength),
                  styledRange == runRange else {
                continue
            }
            storage?.setAttributes(attributeProvider.attributesFor(run.value?.capture), range: styledRange)
        }

        textView.textStorage.endEditing()
    }
}

// MARK: - VisibleRangeProviderDelegate

extension Highlighter: VisibleRangeProviderDelegate {
    func visibleSetDidUpdate(_ newIndices: IndexSet) {
        guard isWithinLimit else { return }
        highlightProviders.forEach { $0.highlightInvalidRanges() }
    }
}
