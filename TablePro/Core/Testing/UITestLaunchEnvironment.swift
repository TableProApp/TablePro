//
//  UITestLaunchEnvironment.swift
//  TablePro
//

import Foundation

/// Launch intents a UI test asks for without driving the menu bar. Read only inside the storage
/// sandbox, so a shipped build ignores these variables.
internal enum UITestLaunchEnvironment {
    internal static let sampleDatabaseVariable = "TABLEPRO_UI_TEST_OPEN_SAMPLE"
    internal static let welcomeSheetVariable = "TABLEPRO_UI_TEST_SHOW_WELCOME_SHEET"
    internal static let dataFileVariable = "TABLEPRO_UI_TEST_OPEN_FILE"
    internal static let connectionShareVariable = "TABLEPRO_UI_TEST_OPEN_CONNECTION_SHARE"

    internal static var requestsWelcomeSheet: Bool {
        isSet(welcomeSheetVariable)
    }

    /// Delivered as ordinary intents, so the launch skips the startup behaviour the way a Finder
    /// open does instead of racing it.
    internal static var launchIntents: [LaunchIntent] {
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
        return intents
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
