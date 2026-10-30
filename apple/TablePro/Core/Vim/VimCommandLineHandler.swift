//
//  VimCommandLineHandler.swift
//  TablePro
//

import Foundation

struct VimCommandLineHandler {
    var onExecuteQuery: (() -> Void)?
    var onCloseTab: (() -> Void)?
    // 1-based position in the tab strip.
    var onSelectTab: ((Int) -> Void)?
    var onSelectAdjacentTab: ((Int) -> Void)?
    var tabCount: (() -> Int)?

    // A count with no tab strip to measure it against stops here, past any strip's length.
    private static let countLimit = 999_999

    private enum TabCommand {
        case next
        case previous
    }

    // Each spelling Vim accepts, from the shortest abbreviation to the full name.
    private static let tabCommands: [String: TabCommand] = {
        var names: [String: TabCommand] = [:]
        for end in 4...7 { names[String("tabnext".prefix(end))] = .next }
        for end in 4...11 { names[String("tabprevious".prefix(end))] = .previous }
        for end in 4...7 { names[String("tabNext".prefix(end))] = .previous }
        return names
    }()

    func handle(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)

        switch trimmed {
        case "w":
            onExecuteQuery?()
        case "q":
            onCloseTab?()
        default:
            handleTabCommand(trimmed)
        }
    }

    private func handleTabCommand(_ command: String) {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true)
        guard let name = parts.first, parts.count <= 2,
              let tabCommand = Self.tabCommands[String(name)] else { return }
        let argument = parts.count == 2 ? String(parts[1]) : nil

        switch tabCommand {
        case .next:
            guard let argument else {
                onSelectAdjacentTab?(1)
                return
            }
            if argument.hasPrefix("+") || argument.hasPrefix("-") {
                guard let offset = relativeCount(argument.dropFirst()) else { return }
                onSelectAdjacentTab?(argument.hasPrefix("-") ? -offset : offset)
            } else if let number = absoluteCount(Substring(argument)) {
                onSelectTab?(number)
            }
        case .previous:
            guard let argument else {
                onSelectAdjacentTab?(-1)
                return
            }
            guard let count = relativeCount(Substring(argument)) else { return }
            onSelectAdjacentTab?(-count)
        }
    }

    private var tabs: Int? {
        tabCount.map { $0() }.flatMap { $0 > 0 ? $0 : nil }
    }

    // Past the last tab is the last tab, as Vim's `goto_tabpage` reads it.
    private func absoluteCount(_ text: Substring) -> Int? {
        Self.count(text, cap: tabs ?? Self.countLimit, modulus: nil)
    }

    // Moving by a multiple of the tab count lands where it started, so the move is reduced to less than one lap.
    private func relativeCount(_ text: Substring) -> Int? {
        Self.count(text, cap: Self.countLimit, modulus: tabs)
    }

    // Read a digit at a time, so a count of any length neither overflows nor leaves the bound.
    private static func count(_ text: Substring, cap: Int, modulus: Int?) -> Int? {
        guard !text.isEmpty else { return nil }
        var value = 0
        var isZero = true
        for character in text {
            guard ("0"..."9").contains(character), let digit = character.wholeNumberValue else { return nil }
            isZero = isZero && digit == 0
            if let modulus {
                value = (value * 10 + digit) % modulus
            } else {
                value = min(value * 10 + digit, cap)
            }
        }
        return isZero ? nil : value
    }
}
