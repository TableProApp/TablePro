//
//  MarkdownInlineRepair.swift
//  TablePro
//

import Foundation

enum MarkdownInlineRepair {
    private static let maximumRepairableLength = 20_000

    private enum OpenDelimiter {
        case codeSpan(runLength: Int)
        case linkTarget
        case strong

        var closingText: String {
            switch self {
            case .codeSpan(let runLength): return String(repeating: "`", count: runLength)
            case .linkTarget: return ")"
            case .strong: return "**"
            }
        }
    }

    private struct ScanResult {
        var stack: [OpenDelimiter] = []
        var trailingRunStart: Int?
        var trailingRunPushed = false
    }

    static func repairingDanglingSyntax(_ source: String) -> String {
        guard !source.isEmpty, (source as NSString).length <= maximumRepairableLength else { return source }
        let characters = Array(source)
        var result = scan(characters)

        var visibleCount = characters.count
        if let trailingRunStart = result.trailingRunStart {
            visibleCount = trailingRunStart
            if result.trailingRunPushed, !result.stack.isEmpty {
                result.stack.removeLast()
            }
        }

        let closers = result.stack.reversed().map(\.closingText).joined()
        if visibleCount == characters.count, closers.isEmpty { return source }
        return String(characters[0..<visibleCount]) + closers
    }

    private static func scan(_ characters: [Character]) -> ScanResult {
        var result = ScanResult()
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if isInsideCodeSpan(result.stack) {
                if character == "`" {
                    index += consumeBacktickRun(at: index, in: characters, result: &result)
                } else {
                    result.trailingRunStart = nil
                    index += 1
                }
                continue
            }

            if character == "\\" {
                result.trailingRunStart = nil
                index += 2
                continue
            }

            if character == "`" {
                index += consumeBacktickRun(at: index, in: characters, result: &result)
                continue
            }

            if character == "]", index + 1 < characters.count, characters[index + 1] == "(" {
                result.stack.append(.linkTarget)
                result.trailingRunStart = nil
                index += 2
                continue
            }

            if character == ")" {
                if case .linkTarget = result.stack.last { result.stack.removeLast() }
                result.trailingRunStart = nil
                index += 1
                continue
            }

            if character == "*" {
                index += consumeAsteriskRun(at: index, in: characters, result: &result)
                continue
            }

            result.trailingRunStart = nil
            index += 1
        }

        return result
    }

    private static func consumeBacktickRun(
        at index: Int,
        in characters: [Character],
        result: inout ScanResult
    ) -> Int {
        let length = runLength(of: "`", in: characters, from: index)
        var closed = false
        var pushed = false

        if case .codeSpan(let openLength) = result.stack.last, openLength == length {
            result.stack.removeLast()
            closed = true
        } else if !isInsideCodeSpan(result.stack) {
            result.stack.append(.codeSpan(runLength: length))
            pushed = true
        }

        recordTrailingRun(start: index, length: length, closed: closed, pushed: pushed, in: characters, result: &result)
        return length
    }

    private static func consumeAsteriskRun(
        at index: Int,
        in characters: [Character],
        result: inout ScanResult
    ) -> Int {
        let length = runLength(of: "*", in: characters, from: index)
        guard length >= 2 else {
            result.trailingRunStart = nil
            return length
        }
        var closed = false
        var pushed = false

        if case .strong = result.stack.last, canClose(at: index, in: characters) {
            result.stack.removeLast()
            closed = true
        } else if canOpen(at: index + length, in: characters) {
            result.stack.append(.strong)
            pushed = true
        }

        recordTrailingRun(start: index, length: length, closed: closed, pushed: pushed, in: characters, result: &result)
        return length
    }

    private static func recordTrailingRun(
        start: Int,
        length: Int,
        closed: Bool,
        pushed: Bool,
        in characters: [Character],
        result: inout ScanResult
    ) {
        guard start + length >= characters.count, !closed else {
            result.trailingRunStart = nil
            return
        }
        result.trailingRunStart = start
        result.trailingRunPushed = pushed
    }

    private static func canOpen(at index: Int, in characters: [Character]) -> Bool {
        guard index < characters.count else { return false }
        return !characters[index].isWhitespace
    }

    private static func canClose(at index: Int, in characters: [Character]) -> Bool {
        guard index > 0 else { return false }
        return !characters[index - 1].isWhitespace
    }

    private static func isInsideCodeSpan(_ stack: [OpenDelimiter]) -> Bool {
        if case .codeSpan = stack.last { return true }
        return false
    }

    private static func runLength(of character: Character, in characters: [Character], from index: Int) -> Int {
        var length = 0
        var cursor = index
        while cursor < characters.count, characters[cursor] == character {
            length += 1
            cursor += 1
        }
        return length
    }
}
