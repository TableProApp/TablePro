//
//  TextViewController+TextFormation.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 1/26/23.
//

import AppKit
import CodeEditTextView
import TextFormation
import TextStory

extension TextViewController {
    // MARK: - Filter Configuration

    /// Initializes any filters for text editing.
    internal func setUpTextFormation() {
        textFilters = []

        // Filters

        setUpOpenPairFilters(pairs: BracketPairs.allValues)
        setUpTagFilter()
        setUpNewlineTabFilters(indentOption: configuration.behavior.indentOption)
        setUpDeletePairFilters(pairs: BracketPairs.allValues)
        setUpDeleteWhitespaceFilter(indentOption: configuration.behavior.indentOption)
    }

    /// Returns a `TextualIndenter` based on available language configuration.
    private func getTextIndenter() -> TextualIndenter {
        switch language.id {
        case .python:
            return TextualIndenter(patterns: TextualIndenter.pythonPatterns)
        case .ruby:
            return TextualIndenter(patterns: TextualIndenter.rubyPatterns)
        default:
            return TextualIndenter(patterns: TextualIndenter.basicPatterns)
        }
    }

    /// Configures pair filters and adds them to the `textFilters` array.
    /// - Parameters:
    ///   - pairs: The pairs to configure. Eg: `{` and `}`
    ///   - whitespaceProvider: The whitespace providers to use.
    private func setUpOpenPairFilters(pairs: [(String, String)]) {
        for pair in pairs {
            let filter = StandardOpenPairFilter(open: pair.0, close: pair.1)
            textFilters.append(filter)
        }
    }

    /// Configures newline and tab replacement filters.
    /// - Parameters:
    ///   - whitespaceProvider: The whitespace providers to use.
    ///   - indentationUnit: The unit of indentation to use.
    private func setUpNewlineTabFilters(indentOption: IndentOption) {
        let newlineFilter: Filter = NewlineProcessingFilter()
        let tabReplacementFilter: Filter = TabReplacementFilter(indentOption: indentOption)

        textFilters.append(contentsOf: [newlineFilter, tabReplacementFilter])
    }

    /// Configures delete pair filters.
    private func setUpDeletePairFilters(pairs: [(String, String)]) {
        for pair in pairs {
            let filter = DeleteCloseFilter(open: pair.0, close: pair.1)
            textFilters.append(filter)
        }
    }

    /// Configures up the delete whitespace filter.
    private func setUpDeleteWhitespaceFilter(indentOption: IndentOption) {
        let filter = DeleteWhitespaceFilter(indentOption: indentOption)
        textFilters.append(filter)
    }

    private func setUpTagFilter() {
        guard let treeSitterClient, language.id.shouldProcessTags() else { return }
        textFilters.append(TagFilter(
            language: self.language,
            indentOption: configuration.behavior.indentOption,
            lineEnding: textView.layoutManager.detectedLineEnding,
            treeSitterClient: treeSitterClient
        ))
    }

    /// Determines whether or not a text mutation should be applied.
    /// - Parameters:
    ///   - mutation: The text mutation.
    ///   - textView: The textView to use.
    /// - Returns: Return whether or not the mutation should be applied.
    internal func shouldApplyMutation(_ mutation: TextMutation, to textView: TextView) -> Bool {
        // don't perform any kind of filtering during undo operations
        if textView.undoManager?.isUndoing ?? false || textView.undoManager?.isRedoing ?? false {
            return true
        }

        let indentationUnit = configuration.behavior.indentOption.stringValue
        let indenter: TextualIndenter = getTextIndenter()
        let whitespaceProvider = WhitespaceProviders(
            leadingWhitespace: indenter.substitionProvider(
                indentationUnit: indentationUnit,
                width: configuration.appearance.tabWidth
            ),
            trailingWhitespace: { _, _ in ""
            }
        )

        for filter in textFilters {
            let action = filter.processMutation(mutation, in: textView, with: whitespaceProvider)
            switch action {
            case .none:
                continue
            case .stop:
                return true
            case .discard:
                return false
            }
        }

        return true
    }
}
