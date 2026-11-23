//
//  ConnectionFacet.swift
//  TablePro
//

import Foundation

enum ConnectionFacet: String, CaseIterable, Hashable, Identifiable, Sendable {
    case general
    case sshAndProxies
    case sslTLS
    case appearance
    case safeMode
    case aiAndMCP
    case startup
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .sshAndProxies: return String(localized: "SSH & Proxies")
        case .sslTLS: return String(localized: "SSL/TLS")
        case .appearance: return String(localized: "Appearance")
        case .safeMode: return String(localized: "Safe Mode")
        case .aiAndMCP: return String(localized: "AI & MCP")
        case .startup: return String(localized: "Startup")
        case .advanced: return String(localized: "Advanced")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .sshAndProxies: return "network"
        case .sslTLS: return "lock.shield"
        case .appearance: return "paintpalette"
        case .safeMode: return "shield.lefthalf.filled"
        case .aiAndMCP: return "sparkles"
        case .startup: return "terminal"
        case .advanced: return "slider.horizontal.3"
        }
    }
}
