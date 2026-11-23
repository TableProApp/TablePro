import Foundation

// Captured at launch: a language change needs a relaunch, so a pending choice is compared with this.
@MainActor
enum LanguageLaunchState {
    private static var launch = LaunchLanguage()

    static var language: AppLanguage {
        launch.capture(AppSettingsManager.shared.general.language)
    }

    static func record() {
        launch.capture(AppSettingsManager.shared.general.language)
    }
}

struct LaunchLanguage {
    private(set) var language: AppLanguage?

    @discardableResult
    mutating func capture(_ current: AppLanguage) -> AppLanguage {
        if let language { return language }
        language = current
        return current
    }
}
