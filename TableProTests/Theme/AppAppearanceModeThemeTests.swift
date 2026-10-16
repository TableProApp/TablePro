//
//  AppAppearanceModeThemeTests.swift
//  TableProTests
//

@testable import TablePro
import TableProTheme
import Testing

struct AppAppearanceModeThemeTests {
    @Test("Auto follows the system appearance, forced modes ignore it")
    func autoFollowsSystem() {
        #expect(AppAppearanceMode.auto.effectiveAppearance(systemIsDark: true) == .dark)
        #expect(AppAppearanceMode.auto.effectiveAppearance(systemIsDark: false) == .light)
        #expect(AppAppearanceMode.light.effectiveAppearance(systemIsDark: true) == .light)
        #expect(AppAppearanceMode.dark.effectiveAppearance(systemIsDark: false) == .dark)
    }
}
