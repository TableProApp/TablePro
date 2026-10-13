import Foundation

/// Device-local on purpose: sync replaces a whole category, so an older Mac would reset these and
/// every zoom press would push a record. One range serves the pickers, zoom and the font caches.
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
        editorFontFamily = container.decodeSetting(.editorFontFamily, default: fallback.editorFontFamily)
        editorFontSize = container.decodeSetting(.editorFontSize, default: fallback.editorFontSize)
        dataGridFontFamily = container.decodeSetting(.dataGridFontFamily, default: fallback.dataGridFontFamily)
        dataGridFontSize = container.decodeSetting(.dataGridFontSize, default: fallback.dataGridFontSize)
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

    /// Nil at either end of the range, which is what dims Zoom In and Zoom Out there.
    internal func editorFontSize(zoomedBy delta: Int) -> Int? {
        let current = clampedEditorFontSize
        let zoomed = Self.clamp(current + delta)
        return zoomed == current ? nil : zoomed
    }
}
