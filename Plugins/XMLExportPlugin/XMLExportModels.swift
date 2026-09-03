//
//  XMLExportModels.swift
//  XMLExportPlugin
//

import Foundation

public struct XMLExportOptions: Equatable, Codable {
    /// Indents each level by two spaces. Off writes one line per row, which is smaller and is what
    /// a parser wants.
    public var prettyPrint: Bool = true

    /// Writes a null as `<column xsi:nil="true"/>` rather than omitting the element. Omitting it
    /// cannot be told apart from a column that was never selected.
    public var marksNulls: Bool = true

    /// The element name each row takes.
    public var rowElementName: String = "row"

    public init() {}

    /// A synthesized `init(from:)` throws `keyNotFound` for a key the saved payload predates and
    /// never falls back to the property's default, so adding one would reset what a user chose.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = XMLExportOptions()
        prettyPrint = try container.decodeIfPresent(Bool.self, forKey: .prettyPrint) ?? defaults.prettyPrint
        marksNulls = try container.decodeIfPresent(Bool.self, forKey: .marksNulls) ?? defaults.marksNulls
        rowElementName = try container.decodeIfPresent(String.self, forKey: .rowElementName)
            ?? defaults.rowElementName
    }
}

/// Escaping and element naming for XML.
///
/// A column name is not automatically a legal element name: XML forbids a leading digit, allows a
/// restricted character set, and reserves names starting with `xml`. A database column has none of
/// those limits, so the name is sanitized rather than trusted.
public enum XMLEscaping {
    public static func text(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default:
                /// XML 1.0 accepts tab, newline and carriage return and no other control character.
                /// A stray 0x00 from a binary column would otherwise make the file unparseable.
                if let scalar = character.unicodeScalars.first,
                   scalar.value < 0x20,
                   character != "\t", character != "\n", character != "\r" {
                    continue
                }
                escaped.append(character)
            }
        }
        return escaped
    }

    /// A legal `Name`, derived from a column name. An empty or wholly illegal name becomes
    /// `column`, so the document still parses.
    public static func elementName(_ value: String) -> String {
        var name = ""
        for (index, character) in value.enumerated() {
            if isNameStart(character) || (index > 0 && isNameCharacter(character)) {
                name.append(character)
            } else if index == 0 {
                name.append("_")
                if isNameCharacter(character) { name.append(character) }
            } else {
                name.append("_")
            }
        }
        guard !name.isEmpty else { return "column" }
        guard !name.lowercased().hasPrefix("xml") else { return "_" + name }
        return name
    }

    private static func isNameStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == ":"
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        isNameStart(character) || character.isNumber || character == "-" || character == "."
    }
}
