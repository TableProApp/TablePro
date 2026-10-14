//
//  CopilotLifecycle.swift
//  TablePro
//

import Foundation

/// The language server is a Node process, so it starts on first use and never at launch, and it
/// stops as soon as the settings no longer allow it.
enum CopilotLifecycle {
    static func allowsRunning(_ settings: AISettings) -> Bool {
        settings.enabled && settings.hasCopilotConfigured
    }

    static func shouldStop(_ settings: AISettings, status: CopilotService.Status) -> Bool {
        status != .stopped && !allowsRunning(settings)
    }
}
