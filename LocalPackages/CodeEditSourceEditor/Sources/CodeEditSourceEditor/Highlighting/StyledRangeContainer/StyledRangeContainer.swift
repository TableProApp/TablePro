//
//  StyledRangeContainer.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 10/13/24.
//

import Foundation

@MainActor
protocol StyledRangeContainerDelegate: AnyObject {
    func styleContainerDidUpdate(in range: NSRange)
}

/// Stores styles for any number of style providers. Provides an API for providers to store their highlights, and for
/// the overlapping highlights to be queried for a final highlight pass.
///
/// See ``runsIn(range:)`` for more details on how conflicting highlights are handled.
@MainActor
class StyledRangeContainer {
    struct StyleElement: RangeStoreElement, CustomDebugStringConvertible {
        var capture: CaptureName?
        var modifiers: CaptureModifierSet

        var isEmpty: Bool {
            capture == nil && modifiers.isEmpty
        }

        func combineLowerPriority(_ other: StyleElement?) -> StyleElement {
            StyleElement(
                capture: self.capture ?? other?.capture,
                modifiers: modifiers.union(other?.modifiers ?? [])
            )
        }

        func combineHigherPriority(_ other: StyleElement?) -> StyleElement {
            StyleElement(
                capture: other?.capture ?? self.capture,
                modifiers: modifiers.union(other?.modifiers ?? [])
            )
        }

        var debugDescription: String {
            "\(capture?.stringValue ?? "(empty)"), \(modifiers)"
        }
    }

    enum RunState {
        case empty
        case value(RangeStoreRun<StyleElement>)
        case exhausted

        var isExhausted: Bool {
            if case .exhausted = self { return true }
            return false
        }

        var hasValue: Bool {
            if case .value = self { return true }
            return false
        }

        var length: Int {
            switch self {
            case .empty, .exhausted:
                return 0
            case .value(let run):
                return run.length
            }
        }
    }

    var _storage: [ProviderID: (store: RangeStore<StyleElement>, priority: Int)] = [:]
    weak var delegate: StyledRangeContainerDelegate?

    /// Initialize the container with a list of provider identifiers. Each provider is given an id, they should be
    /// passed on here so highlights can be associated with a provider for conflict resolution.
    /// - Parameters:
    ///   - documentLength: The length of the document.
    ///   - providers: An array of identifiers given to providers.
    init(documentLength: Int, providers: [ProviderID]) {
        for provider in providers {
            _storage[provider] = (store: RangeStore<StyleElement>(documentLength: documentLength), priority: provider)
        }
    }

    func addProvider(_ id: ProviderID, priority: Int, documentLength: Int) {
        assert(!_storage.keys.contains(id), "Provider already exists")
        _storage[id] = (store: RangeStore<StyleElement>(documentLength: documentLength), priority: priority)
    }

    func setPriority(providerId: ProviderID, priority: Int) {
        _storage[providerId]?.priority = priority
    }

    func removeProvider(_ id: ProviderID) {
        guard let provider = _storage[id]?.store else { return }
        applyHighlightResult(
            provider: id,
            highlights: [],
            rangeToHighlight: NSRange(location: 0, length: provider.length)
        )
        _storage.removeValue(forKey: id)
    }

    func storageUpdated(editedRange: NSRange, changeInLength delta: Int) {
        for key in _storage.keys {
            _storage[key]?.store.storageUpdated(editedRange: editedRange, changeInLength: delta)
        }
    }
}

extension StyledRangeContainer: HighlightProviderStateDelegate {
    func updateStorageLength(newLength: Int) {
        for key in _storage.keys {
            guard var value = _storage[key] else { continue }
            var store = value.store
            let length = store.length
            if length != newLength {
                let missingCharacters = newLength - length
                if missingCharacters < 0 {
                    store.storageUpdated(replacedCharactersIn: (length + missingCharacters)..<length, withCount: 0)
                } else {
                    store.storageUpdated(replacedCharactersIn: length..<length, withCount: missingCharacters)
                }
            }

            value.store = store
            _storage[key] = value
        }
    }

    /// Applies a highlight result from a highlight provider to the storage container.
    /// - Parameters:
    ///   - provider: The provider sending the highlights.
    ///   - highlights: The highlights provided. These cannot be outside the range to highlight, must be ordered by
    ///                 position, but do not need to be continuous. Ranges not included in these highlights will be
    ///                 saved as empty.
    ///   - rangeToHighlight: The range to apply the highlights to.
    func applyHighlightResult(provider: ProviderID, highlights: [HighlightRange], rangeToHighlight: NSRange) {
        assert(rangeToHighlight != .notFound, "NSNotFound is an invalid highlight range")
        guard var storage = _storage[provider]?.store else {
            assertionFailure("No storage found for the given provider: \(provider)")
            return
        }
        var runs: [RangeStoreRun<StyleElement>] = []
        var lastIndex = rangeToHighlight.lowerBound

        for highlight in highlights {
            if highlight.range.lowerBound > lastIndex {
                runs.append(.empty(length: highlight.range.lowerBound - lastIndex))
            } else if highlight.range.lowerBound < lastIndex {
                continue // Skip! Overlapping
            }
            runs.append(
                RangeStoreRun<StyleElement>(
                    length: highlight.range.length,
                    value: StyleElement(capture: highlight.capture, modifiers: highlight.modifiers)
                )
            )
            lastIndex = highlight.range.max
        }

        if lastIndex < rangeToHighlight.upperBound {
            runs.append(.empty(length: rangeToHighlight.upperBound - lastIndex))
        }

        storage.set(runs: runs, for: rangeToHighlight.intRange)
        _storage[provider]?.store = storage
        delegate?.styleContainerDidUpdate(in: rangeToHighlight)
    }
}
