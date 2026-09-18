//
//  PostgresRestoreDiagnostics.swift
//  TablePro
//

import Foundation

internal enum PostgresRestoreDiagnostics {
    private static let errorsIgnoredExitCode: Int32 = 1
    private static let errorsIgnoredPrefix = "pg_restore: warning: errors ignored on restore: "
    private static let phaseContextLines: Set<String> = [
        "pg_restore: while INITIALIZING:",
        "pg_restore: while PROCESSING TOC:"
    ]
    private static let tocEntryContextPrefix = "pg_restore: from TOC entry "
    private static let executeQueryPrefix = "pg_restore: error: could not execute query: "
    private static let couldNotSetPrefix = "pg_restore: error: could not set "
    private static let setCommandPrefix = "Command was: SET "
    private static let unrecognizedParameterPrefix = "ERROR:  unrecognized configuration parameter \""

    internal static func skippedSessionSettings(exitCode: Int32, stderr: String) -> [String]? {
        guard exitCode == errorsIgnoredExitCode else { return nil }
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let summary = lines.last,
              let reportedErrorCount = errorsIgnoredCount(summary),
              let skipped = rejectedSettings(in: lines.dropLast()),
              !skipped.isEmpty,
              skipped.count == reportedErrorCount
        else { return nil }
        return uniqued(skipped)
    }

    private static func rejectedSettings(in lines: ArraySlice<String>) -> [String]? {
        var settings: [String] = []
        var remaining = lines
        while let line = remaining.popFirst() {
            if isContext(line) { continue }
            if let setting = couldNotSetSetting(line) {
                settings.append(setting)
                continue
            }
            guard let command = remaining.popFirst(),
                  let setting = rejectedSetCommandSetting(error: line, command: command)
            else { return nil }
            settings.append(setting)
        }
        return settings
    }

    private static func isContext(_ line: String) -> Bool {
        phaseContextLines.contains(line) || line.hasPrefix(tocEntryContextPrefix)
    }

    private static func errorsIgnoredCount(_ line: String) -> Int? {
        guard line.hasPrefix(errorsIgnoredPrefix) else { return nil }
        return Int(line.dropFirst(errorsIgnoredPrefix.count))
    }

    private static func couldNotSetSetting(_ line: String) -> String? {
        guard line.hasPrefix(couldNotSetPrefix) else { return nil }
        let remainder = line.dropFirst(couldNotSetPrefix.count)
        let quoted = remainder.first == "\""
        let nameStart = quoted ? remainder.index(after: remainder.startIndex) : remainder.startIndex
        let separator = quoted ? "\": " : ": "
        guard let separatorRange = remainder[nameStart...].range(of: separator) else { return nil }
        let setting = String(remainder[nameStart..<separatorRange.lowerBound])
        let serverMessage = String(remainder[separatorRange.upperBound...])
        guard isSettingName(setting), unrecognizedParameter(in: serverMessage) == setting else { return nil }
        return setting
    }

    private static func rejectedSetCommandSetting(error: String, command: String) -> String? {
        guard error.hasPrefix(executeQueryPrefix),
              let setting = unrecognizedParameter(in: String(error.dropFirst(executeQueryPrefix.count)))
        else { return nil }
        let assignment = setCommandPrefix + setting + " = "
        guard command.hasPrefix(assignment), command.hasSuffix(";") else { return nil }
        let value = command.dropFirst(assignment.count).dropLast()
        guard isSingleValue(value) else { return nil }
        return setting
    }

    private static func unrecognizedParameter(in serverMessage: String) -> String? {
        guard serverMessage.hasPrefix(unrecognizedParameterPrefix), serverMessage.hasSuffix("\"") else { return nil }
        let name = String(serverMessage.dropFirst(unrecognizedParameterPrefix.count).dropLast())
        return isSettingName(name) ? name : nil
    }

    private static func isSettingName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { character in
            character == "_" || character == "." || (character.isASCII && (character.isLetter || character.isNumber))
        }
    }

    private static func isSingleValue(_ value: Substring) -> Bool {
        guard value.first == "'" else {
            return !value.isEmpty && value.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || "_.+-".contains(character))
            }
        }
        return isQuotedLiteral(value)
    }

    private static func isQuotedLiteral(_ value: Substring) -> Bool {
        guard value.count >= 2, value.first == "'", value.last == "'" else { return false }
        var inner = value.dropFirst().dropLast()
        while let character = inner.popFirst() {
            guard character == "'" else { continue }
            guard inner.popFirst() == "'" else { return false }
        }
        return true
    }

    private static func uniqued(_ settings: [String]) -> [String] {
        var seen: Set<String> = []
        return settings.filter { seen.insert($0).inserted }
    }
}
