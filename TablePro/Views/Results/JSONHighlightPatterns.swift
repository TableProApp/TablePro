//
//  JSONHighlightPatterns.swift
//  TablePro

import Foundation
import os

private let patternLogger = Logger(subsystem: "com.TablePro", category: "JSONHighlightPatterns")

private func compileJSONRegex(_ pattern: String) -> NSRegularExpression {
    if let regex = try? NSRegularExpression(pattern: pattern) {
        return regex
    }
    patternLogger.fault("Failed to compile JSON highlight pattern: \(pattern, privacy: .public)")
    return NSRegularExpression()
}

internal enum JSONHighlightPatterns {
    static let string = compileJSONRegex("\"(?:[^\"\\\\]|\\\\.)*\"")
    static let key = compileJSONRegex("(\"(?:[^\"\\\\]|\\\\.)*\")\\s*:")
    static let number = compileJSONRegex("(?<=[\\s,:\\[{])-?\\d+\\.?\\d*(?:[eE][+-]?\\d+)?(?=[\\s,\\]}])")
    static let booleanNull = compileJSONRegex("\\b(?:true|false|null)\\b")
}
