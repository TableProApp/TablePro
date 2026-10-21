//
//  InlineSuggestionSourceKind.swift
//  TablePro
//

import Foundation

enum InlineSuggestionSourceKind: Equatable {
    case off
    case copilot
    case chatCompletion
    case appleIntelligence

    static func resolve(settings: AISettings, accessAllowed: @autoclosure () -> Bool) -> InlineSuggestionSourceKind {
        guard settings.enabled, settings.inlineSuggestionsEnabled else { return .off }
        if settings.useAppleIntelligence {
            return accessAllowed() ? .appleIntelligence : .off
        }
        guard let active = settings.activeProvider, accessAllowed() else { return .off }
        return active.type == .copilot ? .copilot : .chatCompletion
    }
}
