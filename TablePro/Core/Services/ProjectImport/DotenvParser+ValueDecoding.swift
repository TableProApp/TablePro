//
//  DotenvParser+ValueDecoding.swift
//  TablePro
//

import Foundation

extension DotenvParser {
    static func readQuoted(
        _ characters: [Character],
        _ index: inout Int,
        delimiter: Character,
        decodingEscapes: Bool
    ) -> String {
        index += 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if decodingEscapes, character == "\\", index + 1 < characters.count {
                value.append(contentsOf: decodeEscape(characters[index + 1]))
                index += 2
                continue
            }
            if character == delimiter {
                index += 1
                skipToLineEnd(characters, &index)
                return value
            }
            value.append(character)
            index += 1
        }
        return value
    }

    static func decodeEscape(_ character: Character) -> String {
        switch character {
        case "n":
            return "\n"
        case "r":
            return "\r"
        case "t":
            return "\t"
        case "\\":
            return "\\"
        case "\"":
            return "\""
        case "'":
            return "'"
        default:
            return "\\\(character)"
        }
    }

    static func readUnquoted(_ characters: [Character], _ index: inout Int) -> String {
        var value = ""
        var previous: Character?
        while index < characters.count {
            let character = characters[index]
            if character == "\n" {
                break
            }
            if character == "#", let previous, previous == " " || previous == "\t" {
                break
            }
            value.append(character)
            previous = character
            index += 1
        }
        skipToLineEnd(characters, &index)
        return value.trimmingCharacters(in: .whitespaces)
    }
}
