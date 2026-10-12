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
struct LibPQPluginConnectionSourceScanTests {
    private static let connectionSource: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { directory.deleteLastPathComponent() }
        return directory
            .appendingPathComponent("Plugins")
            .appendingPathComponent("PostgreSQLDriverPlugin")
            .appendingPathComponent("LibPQPluginConnection.swift")
    }()

    private static let membersReachingTheConnection: Set<String> = [
        "connectionHandle",
        "fetchResults",
        "resolvingUnknownTypes",
        "learnTypeNames",
        "noteCommandTag",
        "applySpatialRendering"
    ]

    private static func pluginSources() throws -> [(name: String, text: String)] {
        try FileManager.default
            .contentsOfDirectory(at: connectionSource.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    private static func isConnectionFile(_ name: String) -> Bool {
        name == "LibPQPluginConnection.swift" || name.hasPrefix("LibPQPluginConnection+")
    }

    private static func matches(_ pattern: String, in text: String) throws -> [NSTextCheckingResult] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return try NSRegularExpression(pattern: pattern).matches(in: text, range: range)
    }

    @Test("Every underscored stored property is read and written while stateLock is held")
    func underscoredStateIsOnlyTouchedUnderStateLock() throws {
        let source = try String(contentsOf: Self.connectionSource, encoding: .utf8)
        let scan = try StateLockScan(source: source)

        #expect(scan.stateNames.isSuperset(of: ["_cachedServerVersion", "_cachedServerVersionNumber", "_isConnected"]))
        #expect(scan.endsBalanced, "The scan lost track of a literal or a brace, so the code after it went unchecked")
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
        #expect(scan.endsBalanced)
        #expect(scan.unlockedAccesses == ["13:_value", "20:_label", "20:_value"])
    }

    @Test("The scan reports a literal it cannot read instead of passing the code after it unchecked")
    func scanReportsLiteralItCannotRead() throws {
        let rawStringEndingInBackslash = """
        final class Sample {
            private var _value = 0
            private let separator = #"\\"#

            func read() -> Int {
                _value
            }
        }
        """
        let regexHoldingQuote = """
        final class Sample {
            private var _value = 0
            private let pattern = /"/

            func read() -> Int {
                _value
            }
        }
        """

        for source in [rawStringEndingInBackslash, regexHoldingQuote] {
            let scan = try StateLockScan(source: source)
            #expect(!scan.endsBalanced, "Read as balanced: \(source)")
        }
    }

    @Test("stateLock is named in no plugin file but the connection's own")
    func stateLockStaysInTheConnectionFile() throws {
        let sources = try Self.pluginSources()
        #expect(sources.contains { $0.name == "LibPQPluginConnection.swift" && $0.text.contains("stateLock") })

        let others = sources.filter { $0.name != "LibPQPluginConnection.swift" && $0.text.contains("stateLock") }
        #expect(others.isEmpty, "stateLock named in \(others.map(\.name))")
    }

    /// Code in an extension file runs inside a block the connection already put on its queue, so a
    /// lock or a dispatch there would be a second owner of the connection's threading.
    @Test("The connection's extension files neither lock nor dispatch")
    func extensionFilesNeitherLockNorDispatch() throws {
        let extensions = try Self.pluginSources().filter { $0.name.hasPrefix("LibPQPluginConnection+") }
        #expect(extensions.count >= 3, "Found only \(extensions.map(\.name))")

        let forbidden = [
            "stateLock", "queue.", "DispatchQueue", "pluginDispatch", ".async {", ".sync {", "withLock", ".lock()"
        ]
        let offenders = extensions.flatMap { source in
            forbidden.filter { source.text.contains($0) }.map { "\(source.name): \($0)" }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// A member moved out of the connection's file loses the compiler's proof that only a block on
    /// the queue calls it. Each one that uses the `PGconn` therefore checks the queue before anything
    /// else, and no file outside the connection's own names it.
    @Test("Every member other files can reach that uses the PGconn checks the queue first")
    func connectionReachingMembersCheckTheQueue() throws {
        let sources = try Self.pluginSources()
        let connectionText = sources.filter { Self.isConnectionFile($0.name) }.map(\.text).joined(separator: "\n")
        let nsText = connectionText as NSString

        for member in Self.membersReachingTheConnection.sorted() {
            let declarationPattern = #"\b(?:func|var)\s+"# + member + #"\b[^{]*\{\s*(\S[^\n]*)"#
            let declarations = try Self.matches(declarationPattern, in: connectionText)
            #expect(declarations.count == 1, "\(member) is declared \(declarations.count) times")
            if let declaration = declarations.first {
                let firstStatement = nsText.substring(with: declaration.range(at: 1))
                #expect(firstStatement == "preconditionOnQueue()", "\(member) opens with \(firstStatement)")
            }

            var namedOutside: [String] = []
            for source in sources where !Self.isConnectionFile(source.name) {
                if try !Self.matches(#"\b"# + member + #"\b"#, in: source.text).isEmpty {
                    namedOutside.append(source.name)
                }
            }
            #expect(namedOutside.isEmpty, "\(member) is named in \(namedOutside)")
        }
    }

    @Test("Every connection member other files can reach that takes the PGconn is one the queue check covers")
    func connectionTakingMembersAreCovered() throws {
        let signature = #"(?m)^\s*((?:private\s+|fileprivate\s+)?)(?:static\s+)?func\s+(\w+)\(([^)]*)\)"#
        var reachable: [String] = []
        var uncovered: [String] = []

        for source in try Self.pluginSources() where Self.isConnectionFile(source.name) {
            let nsText = source.text as NSString
            for match in try Self.matches(signature, in: source.text) where match.range(at: 1).length == 0 {
                let name = nsText.substring(with: match.range(at: 2))
                guard nsText.substring(with: match.range(at: 3)).contains("conn: OpaquePointer") else { continue }
                reachable.append(name)
                if !Self.membersReachingTheConnection.contains(name) { uncovered.append("\(source.name): \(name)") }
            }
        }

        #expect(Set(reachable).isSuperset(of: ["fetchResults", "learnTypeNames", "noteCommandTag"]), "Found only \(reachable)")
        #expect(uncovered.isEmpty, "Not checked for the queue: \(uncovered)")
    }
}

private struct StateLockScan {
    let stateNames: Set<String>
    let unlockedAccesses: [String]
    let endsBalanced: Bool

    init(source: String) throws {
        let declarationPattern = try NSRegularExpression(pattern: #"\b(?:var|let)\s+(_[A-Za-z]\w*)"#)
        let tokenPattern = try NSRegularExpression(
            pattern: #"[{}]|stateLock\.(?:withLock\b|lock\(\)|unlock\(\))|\bdefer\b|(?<!\w)_[A-Za-z]\w*"#
        )
        let masking = Self.maskingCommentsAndLiterals(Array(source.utf16))
        let code = masking.units
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
        endsBalanced = depth == 0 && !masking.endsInsideLiteral
    }

    /// Blanks comments and string literal text to spaces, keeping line breaks and every offset, so
    /// a brace or a property name quoted in SQL or prose is not read as code. Interpolated
    /// expressions stay, because `"\(_value)"` reads the property.
    private static func maskingCommentsAndLiterals(_ units: [UInt16]) -> (units: [UInt16], endsInsideLiteral: Bool) {
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
        return (masked, openDelimiter != nil || !interpolations.isEmpty)
    }
}
