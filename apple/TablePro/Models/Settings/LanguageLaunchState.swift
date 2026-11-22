//
//  LanguageLaunchState.swift
//  TablePro
//

import Foundation

// The UI language in effect for this process, captured once. A language change needs a relaunch,
// so this is the value to compare a pending change against. Lives outside the view layer so the
// comparison does not read a singleton from a SwiftUI view.
@MainActor
enum LanguageLaunchState {
    static let language: AppLanguage = AppSettingsManager.shared.general.language
}
