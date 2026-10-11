import Foundation

/// Device-local on purpose. Fonts used to live inside the theme file, so a zoom shortcut rewrote
/// and saved a whole theme. Moving them into a synced settings category would be worse: sync
/// replaces the whole struct on apply, so a Mac still on an older build would push a payload
/// without these keys and reset the fonts on every other Mac, and each zoom press would push a
/// record. The one range here is shared by the pickers, the zoom commands and the font caches;
/// three disagreeing ranges are what let zoom store a size the renderer clamped away.
internal struct TypographySettings: Codable, Equatable, Sendable {
    internal var editorFontFamily: String
    internal var editorFontSize: Int
    internal var dataGridFontFamily: String
    internal var dataGridFontSize: Int

    internal static let sizeRange = 10...24
    internal static let systemMonoFamily = "System Mono"

    internal static let `default` = TypographySettings(
        editorFontFamily: systemMonoFamily,
        editorFontSize: 13,
        dataGridFontFamily: systemMonoFamily,
        dataGridFontSize: 13
    )

    internal init(
        editorFontFamily: String = systemMonoFamily,
        editorFontSize: Int = 13,
        dataGridFontFamily: String = systemMonoFamily,
        dataGridFontSize: Int = 13
    ) {
        self.editorFontFamily = editorFontFamily
        self.editorFontSize = editorFontSize
        self.dataGridFontFamily = dataGridFontFamily
        self.dataGridFontSize = dataGridFontSize
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TypographySettings.default

        editorFontFamily = try container.decodeIfPresent(String.self, forKey: .editorFontFamily)
            ?? fallback.editorFontFamily
        editorFontSize = try container.decodeIfPresent(Int.self, forKey: .editorFontSize)
            ?? fallback.editorFontSize
        dataGridFontFamily = try container.decodeIfPresent(String.self, forKey: .dataGridFontFamily)
            ?? fallback.dataGridFontFamily
        dataGridFontSize = try container.decodeIfPresent(Int.self, forKey: .dataGridFontSize)
            ?? fallback.dataGridFontSize
    }

    internal var clampedEditorFontSize: Int {
        Self.clamp(editorFontSize)
    }

    internal var clampedDataGridFontSize: Int {
        Self.clamp(dataGridFontSize)
    }

    internal static func clamp(_ size: Int) -> Int {
        min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
    }
}
