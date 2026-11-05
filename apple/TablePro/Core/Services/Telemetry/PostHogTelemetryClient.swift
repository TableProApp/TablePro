import Foundation
import os
import PostHog

// Both apps compile this file, so what the SDK may collect is set once.
@MainActor
internal protocol TelemetryClient: AnyObject {
    func identify(_ accountID: String, personProperties: [String: Any])
    func capture(_ event: String, properties: [String: Any])
    func reset()
    func optIn()
    func optOut()
}

// The SDK keeps its queue in files and sends what is left after the next setup, so quitting needs no flush.
@MainActor
internal final class PostHogTelemetryClient: TelemetryClient {
    nonisolated static let host = "https://eu.i.posthog.com"

    private let projectKey: String
    private var sdk: PostHogSDK?

    init(projectKey: String) {
        self.projectKey = projectKey
        PostHogTransportGate.isOpen = true
        sdk = PostHogSDK.with(Self.configuration(projectKey: projectKey))
    }

    // An unexpanded "$(POSTHOG_PROJECT_KEY)" means the build setting was never defined.
    nonisolated static func projectKey(from infoValue: Any?) -> String? {
        guard let value = infoValue as? String else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty || key.hasPrefix("$(") ? nil : key
    }

    // Only the events Telemetry captures: nothing the SDK would collect, load or swizzle on its own.
    nonisolated static func configuration(projectKey: String) -> PostHogConfig {
        let config = PostHogConfig(projectToken: projectKey, host: host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.capturePushNotificationOpened = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.errorTrackingConfig.autoCapture = false
        config.personProfiles = .identifiedOnly
        let session = URLSessionConfiguration.default
        session.protocolClasses = [PostHogTransportGate.self] + (session.protocolClasses ?? [])
        config.urlSessionConfiguration = session
        // Batched, an event captured just before an opt-out still went out at the next flush, after it.
        config.flushAt = 1
        #if os(iOS)
        // iOS-only integrations, each on by default; surveys would put up the SDK's own sheets.
        config.surveys = false
        config.capturePushNotificationSubscriptions = false
        config.rageClickConfig.enabled = false
        #endif
        return config
    }

    func identify(_ accountID: String, personProperties: [String: Any]) {
        sdk?.identify(accountID, userProperties: personProperties)
    }

    func capture(_ event: String, properties: [String: Any]) {
        sdk?.capture(event, properties: properties)
    }

    func reset() {
        sdk?.reset()
    }

    func optIn() {
        PostHogTransportGate.isOpen = true
        if sdk == nil {
            sdk = PostHogSDK.with(Self.configuration(projectKey: projectKey))
        }
        sdk?.optIn()
    }

    // Closing stops the SDK's queue, which keeps what it holds on disk until the next opt-in.
    func optOut() {
        PostHogTransportGate.isOpen = false
        sdk?.optOut()
        sdk?.close()
        sdk = nil
    }
}

// Refuses every PostHog request while usage data is off. The SDK's optOut() stops captures but not uploads, and its
// close() flushes before it stops, so an event queued offline could otherwise leave after the switch went off.
nonisolated internal final class PostHogTransportGate: URLProtocol, @unchecked Sendable {
    private static let state = OSAllocatedUnfairLock(initialState: false)

    static var isOpen: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        !isOpen
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
