//
//  UITestLaunchEnvironment.swift
//  TablePro
//

import Foundation
import os

/// The launch intents a UI test can ask for without driving the menu bar to get them.
///
/// A test that needs a connected window spends its whole budget reaching one. Clicking
/// `Help > Open Sample Database` costs XCUITest a menu traversal it fails on the first attempt and
/// recovers from ten seconds later, every time, on every test that opens the sample: 66 of the 85
/// cases and 11 of the 39 minutes the UI suite used to take. Asking for the sample at launch is
/// both faster and the thing those tests actually mean, since none of them is testing the Help menu.
/// `SingleWindowMenuContractUITests` still covers that menu item the way a person reaches it.
///
/// The read is gated on the storage sandbox, the same as `ScreenshotEnvironment`. In a shipped
/// build `isIsolated` is false and this variable does nothing; a build that sets
/// `TABLEPRO_UI_TESTING` without a sandbox has already refused to launch.
internal enum UITestLaunchEnvironment {
    internal static let sampleDatabaseVariable = "TABLEPRO_UI_TEST_OPEN_SAMPLE"
    internal static let welcomeSheetVariable = "TABLEPRO_UI_TEST_SHOW_WELCOME_SHEET"
    internal static let dataFileVariable = "TABLEPRO_UI_TEST_OPEN_FILE"
    internal static let connectionShareVariable = "TABLEPRO_UI_TEST_OPEN_CONNECTION_SHARE"
    internal static let openURLVariable = "TABLEPRO_UI_TEST_OPEN_URL"

    private static let logger = Logger(subsystem: "com.TablePro", category: "UITestLaunchEnvironment")

    internal static var requestsWelcomeSheet: Bool {
        isSet(welcomeSheetVariable)
    }

    /// Delivered through the ordinary intent path rather than opened directly, so the launch
    /// counts as one somebody asked for. `runStartupBehaviorIfNeeded(skipping:)` skips a launch
    /// that carries intents, which is what stops the startup behaviour from racing the sample
    /// window onto the screen 150ms later.
    @MainActor internal static var launchIntents: [LaunchIntent] {
        var intents: [LaunchIntent] = []
        if isSet(sampleDatabaseVariable) {
            intents.append(.openSampleDatabase)
        }
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

    /// Classified like a URL macOS hands the app, without going through LaunchServices, which
    /// would deliver it to whichever TablePro is registered for the scheme.
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
