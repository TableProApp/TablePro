//
//  InlineSuggestionSourceKind.swift
//  TablePro
//

import Foundation

enum InlineSuggestionSourceKind: Equatable {
    case off
    case copilot
    case chatCompletion

    static func resolve(settings: AISettings, accessAllowed: @autoclosure () -> Bool) -> InlineSuggestionSourceKind {
        guard settings.enabled, settings.inlineSuggestionsEnabled, let active = settings.activeProvider else {
            return .off
        }
        guard accessAllowed() else { return .off }
        return active.type == .copilot ? .copilot : .chatCompletion
    }
}
