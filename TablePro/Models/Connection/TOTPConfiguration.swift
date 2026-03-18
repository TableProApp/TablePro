//
//  TOTPConfiguration.swift
//  TablePro
//

import Foundation

/// TOTP (Time-based One-Time Password) mode for SSH connections
internal enum TOTPMode: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case autoGenerate = "auto_generate"
    case promptAtConnect = "prompt_at_connect"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "None")
        case .autoGenerate: return String(localized: "Auto Generate")
        case .promptAtConnect: return String(localized: "Prompt at Connect")
        }
    }
}

/// TOTP hash algorithm
internal enum TOTPAlgorithm: String, CaseIterable, Identifiable, Codable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    var id: String { rawValue }
}
