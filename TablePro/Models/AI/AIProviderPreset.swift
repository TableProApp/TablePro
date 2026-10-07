//
//  AIProviderPreset.swift
//  TablePro
//

import Foundation

/// A named vendor that speaks the OpenAI-compatible wire format.
///
/// A preset is stored as a `.custom` provider carrying the preset's id, so a build that has never
/// heard of the vendor still decodes it as a working custom provider. A new `AIProviderType` case
/// cannot do that: its raw value fails to decode on every older build that syncs the same settings.
struct AIProviderPreset: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let endpoint: String
    let symbolName: String
    let authStyle: AIProviderType.AuthStyle
    /// Most servers answer a wrong key with 401. One that answers 403 would otherwise be reported
    /// as a server error, which the chat offers to retry.
    let rejectsBadKeyWithForbidden: Bool

    static let requesty = AIProviderPreset(
        id: "requesty",
        displayName: "Requesty",
        endpoint: "https://router.requesty.ai",
        symbolName: "arrow.triangle.branch",
        authStyle: .apiKey,
        rejectsBadKeyWithForbidden: true
    )

    /// Opper serves its OpenAI-compatible routes under `/v3/compat` with no `/v1`, so the default
    /// names the chat completions route, which `AIEndpoint` trims back to that base.
    static let opper = AIProviderPreset(
        id: "opper",
        displayName: "Opper",
        endpoint: "https://api.opper.ai/v3/compat/chat/completions",
        symbolName: "network",
        authStyle: .apiKey,
        rejectsBadKeyWithForbidden: false
    )

    static let all: [AIProviderPreset] = [.requesty, .opper]

    static func preset(withID id: String?) -> AIProviderPreset? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
