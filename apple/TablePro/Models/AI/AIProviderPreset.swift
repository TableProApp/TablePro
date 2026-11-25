//
//  AIProviderPreset.swift
//  TablePro
//

import Foundation

// Stored as `.custom` plus an id: a new `AIProviderType` case fails to decode on older synced builds.
struct AIProviderPreset: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let endpoint: String
    let icon: BrandIcon
    let authStyle: AIProviderType.AuthStyle
    // A 403 for a wrong key would otherwise read as a server error, which the chat offers to retry.
    let rejectsBadKeyWithForbidden: Bool
    let modelIDs: AIModelIDFilter

    init(
        id: String,
        displayName: String,
        endpoint: String,
        icon: BrandIcon,
        authStyle: AIProviderType.AuthStyle,
        rejectsBadKeyWithForbidden: Bool,
        modelIDs: AIModelIDFilter = .all
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.icon = icon
        self.authStyle = authStyle
        self.rejectsBadKeyWithForbidden = rejectsBadKeyWithForbidden
        self.modelIDs = modelIDs
    }

    static let requesty = AIProviderPreset(
        id: "requesty",
        displayName: "Requesty",
        endpoint: "https://router.requesty.ai",
        icon: BrandIcon(slug: "requesty", fallbackSystemImage: "arrow.triangle.branch"),
        authStyle: .apiKey,
        rejectsBadKeyWithForbidden: true
    )

    static let meta = AIProviderPreset(
        id: "meta",
        displayName: "Meta",
        endpoint: "https://api.meta.ai",
        icon: BrandIcon(slug: "meta", fallbackSystemImage: "infinity.circle"),
        authStyle: .apiKey,
        rejectsBadKeyWithForbidden: false,
        // Meta may train on what a contributor model is sent, so one is used only when typed under Other….
        modelIDs: AIModelIDFilter(unlistedParts: ["-contributor"])
    )

    static let all: [AIProviderPreset] = [.requesty, .meta]

    static func preset(withID id: String?) -> AIProviderPreset? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    // A gateway in the vendor's place names its models its own way, so its list is kept whole.
    func modelIDFilter(forEndpoint endpoint: String) -> AIModelIDFilter {
        guard let host = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(),
              host == URL(string: self.endpoint)?.host?.lowercased()
        else { return .all }
        return modelIDs
    }
}

// Ids a vendor's list holds that are never offered, whatever the catalog says about them.
struct AIModelIDFilter: Equatable, Sendable {
    let unlistedParts: [String]

    static let all = AIModelIDFilter(unlistedParts: [])

    func lists(_ modelID: String) -> Bool {
        !unlistedParts.contains { modelID.contains($0) }
    }
}
