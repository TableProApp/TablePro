//
//  CellValueContentDetector.swift
//  TablePro
//

import Foundation

internal enum CellValueContent: Equatable {
    case json
    case phpSerialized
    case plain
}

internal enum CellValueContentDetector {
    private static let sizeCapBytes = 5_000_000

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

        return .plain
    }
}
