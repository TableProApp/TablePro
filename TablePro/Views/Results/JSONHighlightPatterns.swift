//
//  JSONHighlightPatterns.swift
//  TablePro

import Foundation

// swiftlint:disable force_try
enum JSONHighlightPatterns {
    static let string = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"")
    static let key = try! NSRegularExpression(pattern: "(\"(?:[^\"\\\\]|\\\\.)*\")\\s*:")
    static let number = try! NSRegularExpression(pattern: "(?<=[\\s,:\\[{])-?\\d+\\.?\\d*(?:[eE][+-]?\\d+)?(?=[\\s,\\]}])")
    static let booleanNull = try! NSRegularExpression(pattern: "\\b(?:true|false|null)\\b")
}
// swiftlint:enable force_try
