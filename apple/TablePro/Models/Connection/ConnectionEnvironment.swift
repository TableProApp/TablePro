//
//  ConnectionEnvironment.swift
//  TablePro
//

import Foundation

/// A connection's deployment environment, shown on the identity row so production stands apart from
/// a scratch database at a glance.
///
/// Stored as the app-managed `additionalFields["environment"]` key, so it rides the connection's
/// existing synced field set rather than a new CloudKit field.
enum ConnectionEnvironment: String, CaseIterable, Identifiable, Sendable {
    case none
    case production
    case staging
    case development
    case local

    static let fieldKey = "environment"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "None")
        case .production: return String(localized: "Production")
        case .staging: return String(localized: "Staging")
        case .development: return String(localized: "Development")
        case .local: return String(localized: "Local")
        }
    }

    /// An SF Symbol, never a bare coloured dot: the platform's own vocabulary for status.
    var symbolName: String? {
        switch self {
        case .none: return nil
        case .production: return "exclamationmark.triangle.fill"
        case .staging: return "testtube.2"
        case .development: return "hammer.fill"
        case .local: return "laptopcomputer"
        }
    }
}
