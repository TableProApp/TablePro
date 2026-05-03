//
//  AnalyticsService.swift
//  TablePro
//

import Foundation
import TableProAnalytics

/// macOS analytics entry point. Thin wrapper around the shared AnalyticsHeartbeatService.
@MainActor
final class AnalyticsService {
    static let shared = AnalyticsService()

    private var heartbeatTask: Task<Void, Never>?
    private let service: AnalyticsHeartbeatService

    private init() {
        service = AnalyticsHeartbeatService(provider: MacAnalyticsProvider.shared)
    }

    deinit {
        heartbeatTask?.cancel()
    }

    /// Start periodic heartbeat. Call from AppDelegate.applicationDidFinishLaunching.
    func startPeriodicHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = service.startPeriodicHeartbeat()
    }
}
