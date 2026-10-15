//
//  TOTPConfiguration.swift
//  TablePro
//

import Foundation

public enum TOTPMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "none"
    case autoGenerate = "auto_generate"
    case promptAtConnect = "prompt_at_connect"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return String(localized: "None")
        case .autoGenerate: return String(localized: "Auto Generate")
        case .promptAtConnect: return String(localized: "Prompt at Connect")
        }
    }
}

public enum TOTPAlgorithm: String, CaseIterable, Identifiable, Codable, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    public var id: String { rawValue }
}
