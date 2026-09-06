//
//  CellValueContentDetector.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum CellValueContent: Equatable {
    case json
    case phpSerialized
    case image(CellImageFormat)
    case plain
}

internal enum CellValueContentDetector {
    private static let sizeCapBytes = 5_000_000

    /// The typed answer, and the one both the grid and the row inspector resolve through, so a
    /// value cannot be an image in one and plain text in the other.
    static func detect(_ value: PluginCellValue) -> CellValueContent {
        switch value {
        case .null:
            return .plain
        case .text(let text):
            return detect(text)
        case .bytes(let data):
            guard let format = CellImageSniffer.format(of: data) else { return .plain }
            return .image(format)
        }
    }

    static func detect(_ value: String) -> CellValueContent {
        guard !value.isEmpty else { return .plain }
        guard (value as NSString).length <= sizeCapBytes else { return .plain }

        let first = value.unicodeScalars.first
        if first == "{" || first == "[" {
            if value.looksLikeJson { return .json }
        }

        let phpFirstScalars: Set<Unicode.Scalar> = ["N", "b", "i", "d", "s", "S", "a", "O", "C", "o", "r", "R"]
        if let first, phpFirstScalars.contains(first) {
            if PhpSerializeParser.looksLikePhpSerialized(value) { return .phpSerialized }
        }

        if let format = CellImageSniffer.format(ofText: value) { return .image(format) }

        return .plain
    }
}
