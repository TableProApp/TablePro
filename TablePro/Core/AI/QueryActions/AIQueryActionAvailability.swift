//
//  AIQueryActionAvailability.swift
//  TablePro
//

import Foundation

struct AIQueryActionAvailability: Equatable {
    let isVisible: Bool
    let isEnabled: Bool
    let blockedReason: String?

    init(
        aiEnabled: Bool,
        hasActiveProvider: Bool,
        connectionPolicy: AIConnectionPolicy?,
        isQueryTab: Bool,
        isConnected: Bool,
        hasStatement: Bool
    ) {
        isVisible = aiEnabled && connectionPolicy != .never && isQueryTab
        let reason = Self.reason(
            hasActiveProvider: hasActiveProvider,
            isConnected: isConnected,
            hasStatement: hasStatement
        )
        blockedReason = isVisible ? reason : nil
        isEnabled = isVisible && reason == nil
    }

    static let hidden = AIQueryActionAvailability(
        aiEnabled: false,
        hasActiveProvider: false,
        connectionPolicy: nil,
        isQueryTab: false,
        isConnected: false,
        hasStatement: false
    )

    func hint(base: String) -> String {
        guard let blockedReason else { return base }
        return "\(base)\n\(blockedReason)"
    }

    private static func reason(hasActiveProvider: Bool, isConnected: Bool, hasStatement: Bool) -> String? {
        if !hasActiveProvider { return String(localized: "Add an AI provider in Settings > AI first.") }
        if !hasStatement { return String(localized: "There is no query to send yet.") }
        if !isConnected { return String(localized: "This connection is not available.") }
        return nil
    }
}
