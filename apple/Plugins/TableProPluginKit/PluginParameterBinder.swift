//
//  PluginParameterBinder.swift
//  TableProPluginKit
//

import Foundation

struct PluginParameterBindingError: PluginDriverError {
    let pluginErrorMessage: String
}

// A placeholder counts only in code, as the server lexes it with `features`; a count mismatch means the text was
// read differently from how it was written, so it is refused. `literals` are already written for the engine.
public enum PluginParameterBinder {
    private static let questionMark: UInt16 = 0x3F
    private static let dollar: UInt16 = 0x24
    private static let minus: UInt16 = 0x2D
    private static let space: UInt16 = 0x20

    // The host's reading of the connection, set around a statement it hands to a driver.
    @TaskLocal static var hostFeatures: SQLLexicalFeatures?

    public static func bind(
        _ template: String,
        literals parameters: [String],
        style: ParameterStyle,
        features: SQLLexicalFeatures
    ) throws -> String {
        let lexer = SQLFeatureLexer(template, features: features)
        var bound: [UInt16] = []
        bound.reserveCapacity(lexer.count)
        var nextParameter = 0
        var referenced = Set<Int>()
        var index = 0
        while index < lexer.count {
            if let span = lexer.span(at: index) {
                let end = min(max(span.end, index + 1), lexer.count)
                bound.append(contentsOf: lexer.units[index..<end])
                index = end
                continue
            }
            let unit = lexer.units[index]
            switch style {
            case .questionMark where unit == questionMark:
                guard nextParameter < parameters.count else { throw mismatch(parameters.count) }
                append(parameters[nextParameter], to: &bound)
                nextParameter += 1
                referenced.insert(nextParameter)
                index += 1
                continue
            case .dollar where unit == dollar:
                if let (number, end) = dollarPlaceholder(in: lexer.units, at: index) {
                    guard number >= 1, number <= parameters.count else { throw mismatch(parameters.count) }
                    append(parameters[number - 1], to: &bound)
                    referenced.insert(number)
                    index = end
                    continue
                }
            default:
                break
            }
            bound.append(unit)
            index += 1
        }
        guard referenced.count == parameters.count else { throw mismatch(parameters.count) }
        return String(decoding: bound, as: UTF16.self)
    }

    // `a-?` bound to `-5` would read `a--5`, a line comment to the end of the line.
    private static func append(_ literal: String, to bound: inout [UInt16]) {
        if bound.last == minus, literal.utf16.first == minus {
            bound.append(space)
        }
        bound.append(contentsOf: literal.utf16)
    }

    private static func dollarPlaceholder(in units: [UInt16], at index: Int) -> (Int, Int)? {
        if index > 0, isIdentifierUnit(units[index - 1]) { return nil }
        var cursor = index + 1
        var number = 0
        while cursor < units.count, let digit = digitValue(units[cursor]) {
            guard number < 100_000 else { return nil }
            number = number * 10 + digit
            cursor += 1
        }
        guard cursor > index + 1 else { return nil }
        if cursor < units.count, isIdentifierUnit(units[cursor]) { return nil }
        return (number, cursor)
    }

    private static func digitValue(_ unit: UInt16) -> Int? {
        (0x30...0x39).contains(unit) ? Int(unit - 0x30) : nil
    }

    private static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        digitValue(unit) != nil || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            || unit == 0x5F || unit == dollar || unit >= 0x80
    }

    private static func mismatch(_ count: Int) -> PluginParameterBindingError {
        PluginParameterBindingError(
            pluginErrorMessage: String(
                format: String(localized: "The statement's placeholders do not match the %d values given."),
                count
            )
        )
    }
}
