//
//  DotenvParser+Interpolation.swift
//  TablePro
//

import Foundation

private enum DotenvReference {
    case valid(name: String, defaultValue: String?, length: Int)
    case malformed(length: Int)
}

extension DotenvParser {
    static func resolve(
        _ assignment: DotenvAssignment,
        document: DotenvDocument,
        processEnvironment: [String: String]
    ) -> DotenvEntry {
        guard assignment.quoting != .single else {
            return DotenvEntry(
                key: assignment.key,
                value: assignment.rawValue,
                isSingleQuoted: true,
                hasUnresolvedReference: false
            )
        }
        let characters = Array(assignment.rawValue)
        var value = ""
        var unresolved = false
        var index = 0
        while index < characters.count {
            guard let reference = readReference(characters, at: index) else {
                value.append(characters[index])
                index += 1
                continue
            }
            switch reference {
            case .malformed(let length):
                value.append(literal(characters, from: index, length: length))
                index += length
                unresolved = true
            case .valid(let name, let defaultValue, let length):
                if let resolved = lookUp(name, document: document, processEnvironment: processEnvironment) {
                    value.append(resolved)
                } else if let defaultValue {
                    value.append(defaultValue)
                } else {
                    value.append(literal(characters, from: index, length: length))
                    unresolved = true
                }
                index += length
            }
        }
        return DotenvEntry(
            key: assignment.key,
            value: value,
            isSingleQuoted: false,
            hasUnresolvedReference: unresolved
        )
    }

    private static func literal(_ characters: [Character], from start: Int, length: Int) -> String {
        String(characters[start..<min(start + length, characters.count)])
    }

    private static func lookUp(
        _ name: String,
        document: DotenvDocument,
        processEnvironment: [String: String]
    ) -> String? {
        if let entry = document.entry(for: name), !entry.hasUnresolvedReference {
            return entry.value
        }
        return processEnvironment[name]
    }

    private static func readReference(_ characters: [Character], at start: Int) -> DotenvReference? {
        guard characters[start] == "$", start + 1 < characters.count else {
            return nil
        }
        if characters[start + 1] == "{" {
            return readBracedReference(characters, at: start)
        }
        return readBareReference(characters, at: start)
    }

    private static func readBracedReference(_ characters: [Character], at start: Int) -> DotenvReference {
        var index = start + 2
        var name = ""
        while index < characters.count, characters[index] != "}", characters[index] != ":" {
            name.append(characters[index])
            index += 1
        }
        var defaultValue: String?
        if index < characters.count, characters[index] == ":" {
            var cursor = index + 1
            if cursor < characters.count, characters[cursor] == "-" {
                cursor += 1
            }
            var fallback = ""
            while cursor < characters.count, characters[cursor] != "}" {
                fallback.append(characters[cursor])
                cursor += 1
            }
            defaultValue = fallback
            index = cursor
        }
        guard index < characters.count, characters[index] == "}", isValidReferenceName(name) else {
            let consumed = min(index + 1, characters.count) - start
            return .malformed(length: max(consumed, 2))
        }
        return .valid(name: name, defaultValue: defaultValue, length: index + 1 - start)
    }

    private static func readBareReference(_ characters: [Character], at start: Int) -> DotenvReference? {
        var index = start + 1
        var name = ""
        while index < characters.count {
            let character = characters[index]
            guard character.isLetter || character.isNumber || character == "_" else {
                break
            }
            if name.isEmpty, character.isNumber {
                break
            }
            name.append(character)
            index += 1
        }
        guard !name.isEmpty else {
            return nil
        }
        return .valid(name: name, defaultValue: nil, length: index - start)
    }

    private static func isValidReferenceName(_ name: String) -> Bool {
        guard !name.isEmpty else {
            return false
        }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
