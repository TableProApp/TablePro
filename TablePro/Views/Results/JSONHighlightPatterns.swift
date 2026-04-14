//
//  JSONHighlightPatterns.swift
//  TablePro

import Foundation

// Patterns are compile-time string literals — NSRegularExpression init cannot fail.
// swiftlint:disable force_try
internal enum JSONHighlightPatterns {
    static let string = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"")
    static let key = try! NSRegularExpression(pattern: "(\"(?:[^\"\\\\]|\\\\.)*\")\\s*:")
    static let number = try! NSRegularExpression(pattern: "(?<=[\\s,:\\[{])-?\\d+\\.?\\d*(?:[eE][+-]?\\d+)?(?=[\\s,\\]}])")
    static let booleanNull = try! NSRegularExpression(pattern: "\\b(?:true|false|null)\\b")
}
// swiftlint:enable force_try
