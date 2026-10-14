import Foundation
import os

// Read only under the storage sandbox, so a shipped build ignores every variable here.
internal enum UITestLaunchEnvironment {
    internal static let welcomeSheetVariable = "TABLEPRO_UI_TEST_SHOW_WELCOME_SHEET"
    internal static let dataFileVariable = "TABLEPRO_UI_TEST_OPEN_FILE"
    internal static let connectionShareVariable = "TABLEPRO_UI_TEST_OPEN_CONNECTION_SHARE"
    internal static let openURLVariable = "TABLEPRO_UI_TEST_OPEN_URL"

    private static let logger = Logger(subsystem: "com.TablePro", category: "UITestLaunchEnvironment")

    internal static var requestsWelcomeSheet: Bool {
        isSet(welcomeSheetVariable)
    }

    // Delivered as intents, so `runStartupBehaviorIfNeeded(skipping:)` skips the startup behaviour instead of racing it.
    @MainActor internal static var launchIntents: [LaunchIntent] {
        var intents: [LaunchIntent] = []
        if let dataFileURL = fileURL(in: dataFileVariable) {
            intents.append(.openDataFile(dataFileURL))
        }
        if let connectionShareURL = fileURL(in: connectionShareVariable) {
            intents.append(.openConnectionShare(connectionShareURL))
        }
        if let openURLIntent {
            intents.append(openURLIntent)
        }
        return intents
    }

    // Not through LaunchServices, which would deliver it to whichever TablePro is registered for the scheme.
    @MainActor private static var openURLIntent: LaunchIntent? {
        guard let raw = value(of: openURLVariable), let url = URL(string: raw) else { return nil }
        switch URLClassifier.classify(url) {
        case .some(.success(let intent)):
            return intent
        case .some(.failure(let error)):
            logger.error("UI test URL did not parse: \(error.publicLogShape, privacy: .public)")
            return nil
        case .none:
            logger.error("UI test URL is not one the app opens")
            return nil
        }
    }

    private static func fileURL(in variable: String) -> URL? {
        guard let path = value(of: variable), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func isSet(_ variable: String) -> Bool {
        value(of: variable) != nil
    }

    private static func value(of variable: String) -> String? {
        guard AppStorageEnvironment.shared.isIsolated else { return nil }
        let raw = ProcessInfo.processInfo.environment[variable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}
