//
//  GeneralSettings.swift
//  TablePro
//

import Foundation

enum StartupBehavior: String, Codable, CaseIterable, Identifiable {
    case showWelcome = "showWelcome"
    case reopenLast = "reopenLast"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .showWelcome: return String(localized: "Show Welcome Screen")
        case .reopenLast: return String(localized: "Reopen Last Session")
        }
    }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case vietnamese = "vi"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case korean = "ko"
    case turkish = "tr"
    case french = "fr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .korean: return "한국어"
        case .turkish: return "Türkçe"
        case .french: return "Français"
        }
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

struct GeneralSettings: Codable, Equatable {
    var startupBehavior: StartupBehavior
    var language: AppLanguage

    // 0 means no limit
    var queryTimeoutSeconds: Int
    var shareAnalytics: Bool
    var showRecentTables: Bool
    var showObjectComments: Bool
    var showObjectIcons: Bool
    var showSystemContainers: Bool
    var showPartitions: Bool
    var showWorkspaceRail: Bool
    var showWelcomeVersionInfo: Bool
    var sidebarRowSize: SidebarRowSizePreference
    var connectionHealthCheck: ConnectionHealthCheck

    static let `default` = GeneralSettings(
        startupBehavior: .reopenLast,
        language: .system,
        queryTimeoutSeconds: 60,
        shareAnalytics: true,
        showRecentTables: false,
        showObjectComments: true,
        showObjectIcons: true,
        showSystemContainers: false,
        showPartitions: true,
        showWorkspaceRail: true,
        showWelcomeVersionInfo: true,
        sidebarRowSize: .matchSystem,
        connectionHealthCheck: .every30Seconds
    )

    init(
        startupBehavior: StartupBehavior = .reopenLast,
        language: AppLanguage = .system,
        queryTimeoutSeconds: Int = 60,
        shareAnalytics: Bool = true,
        showRecentTables: Bool = false,
        showObjectComments: Bool = true,
        showObjectIcons: Bool = true,
        showSystemContainers: Bool = false,
        showPartitions: Bool = true,
        showWorkspaceRail: Bool = true,
        showWelcomeVersionInfo: Bool = true,
        sidebarRowSize: SidebarRowSizePreference = .matchSystem,
        connectionHealthCheck: ConnectionHealthCheck = .every30Seconds
    ) {
        self.startupBehavior = startupBehavior
        self.language = language
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.shareAnalytics = shareAnalytics
        self.showRecentTables = showRecentTables
        self.showObjectComments = showObjectComments
        self.showObjectIcons = showObjectIcons
        self.showSystemContainers = showSystemContainers
        self.showPartitions = showPartitions
        self.showWorkspaceRail = showWorkspaceRail
        self.showWelcomeVersionInfo = showWelcomeVersionInfo
        self.sidebarRowSize = sidebarRowSize
        self.connectionHealthCheck = connectionHealthCheck
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        startupBehavior = container.decodeSetting(.startupBehavior, default: fallback.startupBehavior)
        language = container.decodeSetting(.language, default: fallback.language)
        queryTimeoutSeconds = container.decodeSetting(.queryTimeoutSeconds, default: fallback.queryTimeoutSeconds)
        shareAnalytics = container.decodeSetting(.shareAnalytics, default: fallback.shareAnalytics)
        showRecentTables = container.decodeSetting(.showRecentTables, default: fallback.showRecentTables)
        showObjectComments = container.decodeSetting(.showObjectComments, default: fallback.showObjectComments)
        showObjectIcons = container.decodeSetting(.showObjectIcons, default: fallback.showObjectIcons)
        showSystemContainers = container.decodeSetting(.showSystemContainers, default: fallback.showSystemContainers)
        showPartitions = container.decodeSetting(.showPartitions, default: fallback.showPartitions)
        showWorkspaceRail = container.decodeSetting(.showWorkspaceRail, default: fallback.showWorkspaceRail)
        showWelcomeVersionInfo = container.decodeSetting(.showWelcomeVersionInfo, default: fallback.showWelcomeVersionInfo)
        sidebarRowSize = container.decodeSetting(.sidebarRowSize, default: fallback.sidebarRowSize)
        connectionHealthCheck = container.decodeSetting(.connectionHealthCheck, default: fallback.connectionHealthCheck)
    }
}
