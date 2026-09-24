//
//  UITestLaunchEnvironment.swift
//  TablePro
//

import Foundation

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

    internal static var requestsWelcomeSheet: Bool {
        isSet(welcomeSheetVariable)
    }

    /// Delivered through the ordinary intent path rather than opened directly, so the launch
    /// counts as one somebody asked for. `runStartupBehaviorIfNeeded(skipping:)` skips a launch
    /// that carries intents, which is what stops the startup behaviour from racing the sample
    /// window onto the screen 150ms later.
    internal static var launchIntents: [LaunchIntent] {
        var intents: [LaunchIntent] = []
        if isSet(sampleDatabaseVariable) {
            intents.append(.openSampleDatabase)
        }
        if let dataFileURL {
            intents.append(.openDataFile(dataFileURL))
        }
        return intents
    }

    private static var dataFileURL: URL? {
        guard let path = value(of: dataFileVariable), path.hasPrefix("/") else { return nil }
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
