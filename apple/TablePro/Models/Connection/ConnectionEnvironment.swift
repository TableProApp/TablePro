//
//  ConnectionEnvironment.swift
//  TablePro
//

import SwiftUI

// Stored as the app-managed `additionalFields["environment"]` key, so it syncs with the existing field set.
enum ConnectionEnvironment: String, CaseIterable, Identifiable, Sendable {
    case none
    case production
    case staging
    case development
    case local

    static let fieldKey = "environment"

    // A value from a newer release, or a hand-edited file, shows as no environment.
    static func stored(in fields: [String: String]?) -> ConnectionEnvironment {
        fields?[fieldKey].flatMap(ConnectionEnvironment.init(rawValue:)) ?? .none
    }

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

    // Production avoids the triangle: a row's failed status and missing driver already draw it.
    var symbolName: String? {
        switch self {
        case .none: return nil
        case .production: return "flame.fill"
        case .staging: return "testtube.2"
        case .development: return "hammer.fill"
        case .local: return "laptopcomputer"
        }
    }

    var tint: Color {
        switch self {
        case .production: return .red
        case .staging: return .orange
        case .development: return .green
        case .local, .none: return .secondary
        }
    }

    // "Local" alone would read like the row's "Local only" sync flag.
    var accessibilityName: String? {
        switch self {
        case .none: return nil
        case .production: return String(localized: "Production environment")
        case .staging: return String(localized: "Staging environment")
        case .development: return String(localized: "Development environment")
        case .local: return String(localized: "Local environment")
        }
    }
}
