//
//  AIModelListFetchGate.swift
//  TablePro
//

import Foundation

/// Whether a provider's model list can be fetched yet, and why not.
///
/// This lives outside the settings sheet so the rule can be tested. The sheet used to clear its
/// error state in the case that blocks the fetch, which left the Model picker empty with nothing
/// said and no way to retry.
internal enum AIModelListFetchGate {
    internal enum Blocker: Equatable {
        case notFetchable
        case missingEndpoint
        case missingAPIKey
    }

    internal static func blocker(
        fetchesModelList: Bool,
        takesEndpoint: Bool,
        endpoint: String,
        authStyle: AIProviderType.AuthStyle,
        apiKey: String
    ) -> Blocker? {
        guard fetchesModelList else { return .notFetchable }
        if takesEndpoint, endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingEndpoint
        }
        guard authStyle == .apiKey else { return nil }
        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missingAPIKey : nil
    }
}
