//
//  CSVEncodingReport.swift
//  CSVExportPlugin
//

import Foundation
import TableProPluginKit

/// What an export had to give up to reach the chosen encoding.
///
/// Foundation substitutes `?` for a character an encoding cannot represent and says nothing, so a
/// file that lost half its names looks exactly like one that lost nothing. This collects the
/// distinct characters as the rows go past and turns them into the warning the export dialog
/// already knows how to show.
struct CSVEncodingReport {
    /// Enough to recognise what was lost without filling an alert. A result holding thousands of
    /// distinct unrepresentable characters says the same thing as one holding twelve: the encoding
    /// is wrong for this data.
    static let maxListedCharacters = 12

    private(set) var characters: [Character] = []
    private var seen: Set<Character> = []

    /// One past the list's length, so the warning can say there were more without counting them
    /// all. Once it is true the export stops scanning, which is the difference between a warning
    /// and minutes of naming the same characters on every row of a large table.
    var isSaturated: Bool { characters.count > Self.maxListedCharacters }

    mutating func record(_ found: [Character]) {
        for character in found {
            guard !isSaturated else { return }
            guard seen.insert(character).inserted else { continue }
            characters.append(character)
        }
    }

    /// Names the characters rather than counting them. A count here would be the number of
    /// distinct characters, which reads as a number of values and is not what the reader would
    /// take it for.
    func warnings(for encoding: PluginTextEncoding) -> [String] {
        guard !characters.isEmpty else { return [] }
        let listed = characters
            .prefix(Self.maxListedCharacters)
            .map(Self.rendered)
            .joined(separator: ", ")
        guard isSaturated else {
            return [String(
                format: String(localized: "%1$@ could not represent %2$@. Each was written as \"?\"."),
                encoding.displayName,
                listed
            )]
        }
        return [String(
            format: String(
                localized: "%1$@ could not represent %2$@ and other characters. Each was written as \"?\"."
            ),
            encoding.displayName,
            listed
        )]
    }

    /// A control or format character has no glyph, so printing it leaves the warning ending in a
    /// colon with nothing after it. Those are named by code point instead.
    private static func rendered(_ character: Character) -> String {
        let unprintable: Set<Unicode.GeneralCategory> = [
            .control, .format, .unassigned, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator
        ]
        let printable = character.unicodeScalars.allSatisfy {
            !unprintable.contains($0.properties.generalCategory)
        }
        guard printable else {
            return character.unicodeScalars
                .map { String(format: "U+%04X", $0.value) }
                .joined(separator: " ")
        }
        return String(character)
    }
}
