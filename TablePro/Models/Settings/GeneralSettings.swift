//
//  GeneralSettings.swift
//  TablePro
//

import Foundation

/// Startup behavior when app launches
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

/// App language options
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case vietnamese = "vi"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case turkish = "tr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .turkish: return "Türkçe"
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

/// General app settings
struct GeneralSettings: Codable, Equatable {
    var startupBehavior: StartupBehavior
    var language: AppLanguage
    var automaticallyCheckForUpdates: Bool

    /// Query execution timeout in seconds (0 = no limit)
    var queryTimeoutSeconds: Int

    /// Whether to share anonymous usage analytics
    var shareAnalytics: Bool

    static let `default` = GeneralSettings(
        startupBehavior: .reopenLast,
        language: .system,
        automaticallyCheckForUpdates: true,
        queryTimeoutSeconds: 60,
        shareAnalytics: true
    )

    init(
        startupBehavior: StartupBehavior = .reopenLast,
        language: AppLanguage = .system,
        automaticallyCheckForUpdates: Bool = true,
        queryTimeoutSeconds: Int = 60,
        shareAnalytics: Bool = true
    ) {
        self.startupBehavior = startupBehavior
        self.language = language
        self.automaticallyCheckForUpdates = automaticallyCheckForUpdates
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.shareAnalytics = shareAnalytics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startupBehavior = try container.decode(StartupBehavior.self, forKey: .startupBehavior)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        automaticallyCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCheckForUpdates) ?? true
        queryTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .queryTimeoutSeconds) ?? 60
        shareAnalytics = try container.decodeIfPresent(Bool.self, forKey: .shareAnalytics) ?? true
    }
}
