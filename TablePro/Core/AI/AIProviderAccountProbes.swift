//
//  AIProviderAccountProbes.swift
//  TablePro
//

import Foundation

/// A sign-in status in Settings > AI costs a Keychain read or a spawned CLI, so it is checked only
/// for a provider the user has added, and not at all while AI is off.
enum AIProviderAccountProbes {
    static let probedTypes: Set<AIProviderType> = [.chatgptCodex, .claudeAgent]

    static func types(toProbe settings: AISettings) -> Set<AIProviderType> {
        guard settings.enabled else { return [] }
        return Set(settings.providers.map(\.type)).intersection(probedTypes)
    }
}
