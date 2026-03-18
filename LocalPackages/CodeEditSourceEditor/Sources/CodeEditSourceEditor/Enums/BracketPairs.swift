//
//  BracketPairs.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/5/25.
//

enum BracketPairs {
    static let allValues: [(String, String)] = [
        ("{", "}"),
        ("[", "]"),
        ("(", ")"),
        ("\"", "\""),
        ("'", "'")
    ]

    static let emphasisValues: [(String, String)] = [
        ("{", "}"),
        ("[", "]"),
        ("(", ")")
    ]

    /// Checks if the given string is a matchable emphasis string.
    /// - Parameter potentialMatch: The string to check for matches.
    /// - Returns: True if a match was found with either start or end bracket pairs.
    static func matches(_ potentialMatch: String) -> Bool {
        allValues.contains(where: { $0.0 == potentialMatch || $0.1 == potentialMatch })
    }
}
