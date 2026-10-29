//
//  PostHogTelemetryClient.swift
//  TablePro
//

import Foundation
import PostHog

// The SDK keeps its queue in files and sends what is left after the next setup, so quitting needs no flush.
@MainActor
internal final class PostHogTelemetryClient: TelemetryClient {
    private let sdk: PostHogSDK

    init(projectKey: String) {
        sdk = PostHogSDK.with(Self.configuration(projectKey: projectKey))
    }

    // Only the events Telemetry captures: nothing the SDK would collect, load or swizzle on its own.
    nonisolated static func configuration(projectKey: String) -> PostHogConfig {
        let config = PostHogConfig(projectToken: projectKey, host: Telemetry.host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.capturePushNotificationOpened = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.errorTrackingConfig.autoCapture = false
        config.personProfiles = .identifiedOnly
        return config
    }

    func identify(_ accountID: String, personProperties: [String: Any]) {
        sdk.identify(accountID, userProperties: personProperties)
    }

    func capture(_ event: String, properties: [String: Any]) {
        sdk.capture(event, properties: properties)
    }

    func reset() {
        sdk.reset()
    }

    func optIn() {
        sdk.optIn()
    }

    func optOut() {
        sdk.optOut()
    }
}
