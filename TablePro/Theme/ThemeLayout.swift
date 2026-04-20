//
//  ThemeLayout.swift
//  TablePro
//

import Foundation

// MARK: - Theme Fonts

internal struct ThemeFonts: Codable, Equatable, Sendable {
    var editorFontFamily: String
    var editorFontSize: Int
    var dataGridFontFamily: String
    var dataGridFontSize: Int

    static let `default` = ThemeFonts(
        editorFontFamily: "System Mono",
        editorFontSize: 13,
        dataGridFontFamily: "System Mono",
        dataGridFontSize: 13
    )

    init(editorFontFamily: String, editorFontSize: Int, dataGridFontFamily: String, dataGridFontSize: Int) {
        self.editorFontFamily = editorFontFamily
        self.editorFontSize = editorFontSize
        self.dataGridFontFamily = dataGridFontFamily
        self.dataGridFontSize = dataGridFontSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThemeFonts.default

        editorFontFamily = try container.decodeIfPresent(String.self, forKey: .editorFontFamily)
            ?? fallback.editorFontFamily
        editorFontSize = try container.decodeIfPresent(Int.self, forKey: .editorFontSize) ?? fallback.editorFontSize
        dataGridFontFamily = try container.decodeIfPresent(String.self, forKey: .dataGridFontFamily)
            ?? fallback.dataGridFontFamily
        dataGridFontSize = try container.decodeIfPresent(Int.self, forKey: .dataGridFontSize)
            ?? fallback.dataGridFontSize
    }
}
