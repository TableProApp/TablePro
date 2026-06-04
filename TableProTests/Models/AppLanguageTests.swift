//
//  AppLanguageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private func makeAppLanguageDefaults() -> (UserDefaults, String) {
    let suiteName = "TablePro.AppLanguageTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

@Suite("AppLanguage")
struct AppLanguageTests {
    @Test("sets AppleLanguages through injected defaults")
    func setsAppleLanguages() {
        let (defaults, suiteName) = makeAppLanguageDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppLanguage.vietnamese.apply(userDefaults: defaults)

        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["vi"])
    }

    @Test("removes AppleLanguages for system language")
    func removesAppleLanguagesForSystem() {
        let (defaults, suiteName) = makeAppLanguageDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["en"], forKey: "AppleLanguages")

        AppLanguage.system.apply(userDefaults: defaults)

        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil)
    }
}
