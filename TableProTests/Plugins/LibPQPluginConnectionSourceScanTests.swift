//
//  LibPQPluginConnectionSourceScanTests.swift
//  TableProTests
//

import Foundation
import Testing

/// `LibPQPluginConnection` keeps its shared state in underscored stored properties that the
/// connection's queue writes and any thread reads, so each one is only safe while `stateLock` is
/// held. The server version cache broke that: `disconnect()` cleared it after releasing the lock
/// while `serverVersion()` read it with no lock at all, which ThreadSanitizer reported as a data
/// race against PostgreSQL 17.11. Nothing at runtime shows such a race, and the class imports
/// CLibPQ, which this target cannot, so the guard is a source scan.
@Suite("LibPQPluginConnection source scan")
struct LibPQPluginConnectionSourceScanTests {
    private static let connectionSource: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { directory.deleteLastPathComponent() }
        return directory
            .appendingPathComponent("Plugins")
            .appendingPathComponent("PostgreSQLDriverPlugin")
            .appendingPathComponent("LibPQPluginConnection.swift")
    }()

    @Test("Every underscored stored property is read and written while stateLock is held")
    func underscoredStateIsOnlyTouchedUnderStateLock() throws {
        let source = try String(contentsOf: Self.connectionSource, encoding: .utf8)
        let scan = try StateLockScan(source: source)

        #expect(scan.stateNames.isSuperset(of: ["_cachedServerVersion", "_cachedServerVersionNumber", "_isConnected"]))
        #expect(scan.unlockedAccesses.isEmpty, "Touched without stateLock held: \(scan.unlockedAccesses)")
    }

    @Test("The scan flags an access outside the lock and accepts each way the file takes it")
    func scanTellsLockedFromUnlockedAccess() throws {
        let source = """
        final class Sample {
            private let stateLock = NSLock()
            private var _value = 0
            private var _label: String?

            var value: Int {
                stateLock.lock()
                defer { stateLock.unlock() }
                return _value
            }

            func read() -> Int {
                _value
            }

            func write(_ newValue: Int) {
                stateLock.lock()
                _value = newValue
                stateLock.unlock()
                _label = "_value { \\(_value) \\"_value\\" }"
            }

            func label() -> String? {
                // _label is read under the lock {
                let sql = \"""
                    SELECT "_value" FROM t WHERE a = '{'
                    \"""
                return stateLock.withLock {
                    _label ?? sql
                }
            }
        }
        """

        let scan = try StateLockScan(source: source)

        #expect(scan.stateNames == ["_value", "_label"])
        #expect(scan.unlockedAccesses == ["13:_value", "20:_label", "20:_value"])
    }
}

private struct StateLockScan {
    let stateNames: Set<String>
    let unlockedAccesses: [String]

    init(source: String) throws {
        let declarationPattern = try NSRegularExpression(pattern: #"\b(?:var|let)\s+(_[A-Za-z]\w*)"#)
        let tokenPattern = try NSRegularExpression(
            pattern: #"[{}]|stateLock\.(?:withLock\b|lock\(\)|unlock\(\))|\bdefer\b|(?<!\w)_[A-Za-z]\w*"#
        )
        let code = Self.maskingCommentsAndLiterals(Array(source.utf16))
        let text = String(decoding: code, as: UTF16.self)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        let declarations = declarationPattern.matches(in: text, range: fullRange).map { $0.range(at: 1) }
        let declarationOffsets = Set(declarations.map(\.location))
        let names = Set(declarations.map { nsText.substring(with: $0) })

        var depth = 0
        var lockedClosureDepths: [Int] = []
        var deferDepths: [Int] = []
        var heldLockDepth: Int?
        var opensLockedClosure = false
        var opensDefer = false
        var line = 1
        var scanned = 0
        var unlocked: [String] = []

        for match in tokenPattern.matches(in: text, range: fullRange) {
            while scanned < match.range.location {
                if code[scanned] == UInt16(UInt8(ascii: "\n")) { line += 1 }
                scanned += 1
            }
            let token = nsText.substring(with: match.range)
            switch token {
            case "{":
                depth += 1
                if opensLockedClosure { lockedClosureDepths.append(depth) }
                if opensDefer { deferDepths.append(depth) }
                opensLockedClosure = false
                opensDefer = false
            case "}":
                if lockedClosureDepths.last == depth { lockedClosureDepths.removeLast() }
                if deferDepths.last == depth { deferDepths.removeLast() }
                depth -= 1
                if let held = heldLockDepth, depth < held { heldLockDepth = nil }
            case "stateLock.withLock":
                opensLockedClosure = true
            case "stateLock.lock()":
                heldLockDepth = depth
            case "stateLock.unlock()":
                if deferDepths.isEmpty { heldLockDepth = nil }
            case "defer":
                opensDefer = true
            default:
                guard names.contains(token), !declarationOffsets.contains(match.range.location) else { continue }
                guard lockedClosureDepths.isEmpty, heldLockDepth == nil else { continue }
                unlocked.append("\(line):\(token)")
            }
        }

        stateNames = names
        unlockedAccesses = unlocked
    }

    /// Blanks comments and string literal text to spaces, keeping line breaks and every offset, so
    /// a brace or a property name quoted in SQL or prose is not read as code. Interpolated
    /// expressions stay, because `"\(_value)"` reads the property.
    private static func maskingCommentsAndLiterals(_ units: [UInt16]) -> [UInt16] {
        let newline = UInt16(UInt8(ascii: "\n"))
        let quote = UInt16(UInt8(ascii: "\""))
        let slash = UInt16(UInt8(ascii: "/"))
        let star = UInt16(UInt8(ascii: "*"))
        let backslash = UInt16(UInt8(ascii: "\\"))
        let openParen = UInt16(UInt8(ascii: "("))
        let closeParen = UInt16(UInt8(ascii: ")"))

        var masked = units
        var index = 0
        var parenDepth = 0
        var openDelimiter: Int?
        var interpolations: [(parenDepth: Int, delimiter: Int)] = []

        func unit(at offset: Int) -> UInt16 {
            offset < units.count ? units[offset] : 0
        }
        func delimiterLength(at offset: Int) -> Int {
            unit(at: offset + 1) == quote && unit(at: offset + 2) == quote ? 3 : 1
        }
        func blank(_ count: Int) {
            for offset in index..<min(index + count, units.count) where masked[offset] != newline {
                masked[offset] = UInt16(UInt8(ascii: " "))
            }
            index += count
        }

        while index < units.count {
            let current = units[index]
            let next = unit(at: index + 1)

            if let delimiter = openDelimiter {
                if current == backslash, next == openParen {
                    interpolations.append((parenDepth: parenDepth, delimiter: delimiter))
                    openDelimiter = nil
                    blank(2)
                } else if current == backslash {
                    blank(2)
                } else if current == quote, delimiter == 1 || delimiterLength(at: index) == 3 {
                    openDelimiter = nil
                    blank(delimiter)
                } else {
                    blank(1)
                }
                continue
            }

            if current == slash, next == slash {
                while index < units.count, units[index] != newline { blank(1) }
            } else if current == slash, next == star {
                while index < units.count, !(units[index] == star && unit(at: index + 1) == slash) { blank(1) }
                blank(2)
            } else if current == quote {
                let delimiter = delimiterLength(at: index)
                openDelimiter = delimiter
                blank(delimiter)
            } else if current == closeParen, let interpolation = interpolations.last,
                      interpolation.parenDepth == parenDepth {
                interpolations.removeLast()
                openDelimiter = interpolation.delimiter
                blank(1)
            } else {
                if current == openParen { parenDepth += 1 }
                if current == closeParen { parenDepth -= 1 }
                index += 1
            }
        }
        return masked
    }
}
