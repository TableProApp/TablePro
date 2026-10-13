import Foundation
@testable import TablePro
import Testing

struct LegacyThemeFontsTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-theme-fonts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The shape TablePro 0.80 wrote: format 1, with the fonts inside the theme.
    @discardableResult
    private func writeTheme(
        id: String,
        editorSize: Int? = nil,
        dataGridSize: Int? = nil,
        editorFamily: String? = nil,
        fileName: String? = nil,
        in directory: URL
    ) throws -> URL {
        var fonts: [String: Any] = [:]
        fonts["editorFontSize"] = editorSize
        fonts["dataGridFontSize"] = dataGridSize
        fonts["editorFontFamily"] = editorFamily

        var object: [String: Any] = ["id": id, "name": id, "version": 1, "appearance": "dark"]
        if !fonts.isEmpty {
            object["fonts"] = fonts
        }

        let url = directory.appendingPathComponent(fileName ?? "\(id).json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private func appearance(_ mode: AppAppearanceMode) -> AppearanceSettings {
        AppearanceSettings(appearanceMode: mode, preferredLightThemeId: "user.light", preferredDarkThemeId: "user.dark")
    }

    @Test("Dark mode carries the fonts of the theme in the dark slot")
    func darkModeReadsTheDarkSlot() throws {
        let directory = try makeDirectory()
        try writeTheme(id: "user.light", editorSize: 12, in: directory)
        try writeTheme(id: "user.dark", editorSize: 16, in: directory)

        let carried = LegacyThemeFonts.read(appearance: appearance(.dark), systemIsDark: false, themesDirectory: directory)
        #expect(carried.editorFontSize == 16)
    }

    @Test("Auto follows the system appearance at the moment of the upgrade")
    func autoFollowsTheSystem() throws {
        let directory = try makeDirectory()
        try writeTheme(id: "user.light", editorSize: 12, in: directory)
        try writeTheme(id: "user.dark", editorSize: 16, in: directory)

        let night = LegacyThemeFonts.read(appearance: appearance(.auto), systemIsDark: true, themesDirectory: directory)
        let day = LegacyThemeFonts.read(appearance: appearance(.auto), systemIsDark: false, themesDirectory: directory)
        #expect(night.editorFontSize == 16)
        #expect(day.editorFontSize == 12)
    }

    @Test("The other slot fills in when the theme on screen carried no fonts")
    func otherSlotFillsIn() throws {
        let directory = try makeDirectory()
        try writeTheme(id: "user.light", editorSize: 15, in: directory)
        try writeTheme(id: "user.dark", in: directory)

        let carried = LegacyThemeFonts.read(appearance: appearance(.dark), systemIsDark: true, themesDirectory: directory)
        #expect(carried.editorFontSize == 15)
    }

    /// 0.80 stored zoom up to 24 but drew the editor at 11...18 and the grid at 10...18.
    @Test("A stored size outside what 0.80 drew carries as the size it drew")
    func sizesCarryAsDrawn() throws {
        let directory = try makeDirectory()
        try writeTheme(id: "user.dark", editorSize: 24, dataGridSize: 9, in: directory)
        try writeTheme(id: "user.light", editorSize: 9, dataGridSize: 24, in: directory)

        let dark = LegacyThemeFonts.read(appearance: appearance(.dark), systemIsDark: true, themesDirectory: directory)
        #expect(dark.editorFontSize == 18)
        #expect(dark.dataGridFontSize == 10)

        let light = LegacyThemeFonts.read(appearance: appearance(.light), systemIsDark: false, themesDirectory: directory)
        #expect(light.editorFontSize == 11)
        #expect(light.dataGridFontSize == 18)
    }

    @Test("A theme file named by the user rather than by its id is still found")
    func fileNameNeedNotMatchTheId() throws {
        let directory = try makeDirectory()
        try writeTheme(id: "user.dark", editorSize: 17, editorFamily: "Menlo", fileName: "My Theme.json", in: directory)

        let carried = LegacyThemeFonts.read(appearance: appearance(.dark), systemIsDark: true, themesDirectory: directory)
        #expect(carried.editorFontSize == 17)
        #expect(carried.editorFontFamily == "Menlo")
    }

    @Test("No old theme files leaves the default fonts")
    func nothingToCarry() throws {
        let directory = try makeDirectory()
        let carried = LegacyThemeFonts.read(appearance: appearance(.dark), systemIsDark: true, themesDirectory: directory)
        #expect(carried == .default)
    }

    @Test("The first load writes the carried fonts once and leaves the theme file untouched")
    func firstLoadWritesOnce() throws {
        let directory = try makeDirectory()
        let file = try writeTheme(id: "user.dark", editorSize: 16, in: directory)
        let original = try Data(contentsOf: file)

        let defaults = try #require(UserDefaults(suiteName: "legacy-theme-fonts-\(UUID().uuidString)"))
        let storage = AppSettingsStorage(userDefaults: defaults)
        storage.saveAppearance(appearance(.dark))

        let first = storage.loadTypography(systemIsDark: true, legacyThemesDirectory: directory)
        #expect(first.editorFontSize == 16)
        let afterLoad = try Data(contentsOf: file)
        #expect(afterLoad == original)

        try writeTheme(id: "user.dark", editorSize: 12, in: directory)
        let second = storage.loadTypography(systemIsDark: true, legacyThemesDirectory: directory)
        #expect(second.editorFontSize == 16)
    }
}
