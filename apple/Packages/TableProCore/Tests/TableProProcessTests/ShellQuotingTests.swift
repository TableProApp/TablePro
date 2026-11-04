import Foundation
@testable import TableProProcess
import Testing

// Seeded, so a failure names an input that reproduces.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

private let hostileScalars: [Unicode.Scalar] = [
    "'", "\"", "`", "\\", "$", "!", "*", "?", "[", ";", "&", "|", "<", ">", "(", ")", "{", "}", "#", "~", " ",
    "\n", "\r", "\t", "\u{1}", "\u{7F}", "a", "Z", "0", "-",
    "\u{301}", "\u{300}", "\u{20DD}", "\u{FE0F}", "\u{200D}", "\u{200C}", "\u{34F}", "\u{1F3FB}",
    "\u{E0001}", "\u{FEFF}", "\u{202E}", "\u{2028}", "\u{85}", "\u{AC00}", "\u{1F600}", "\u{10FFFF}", "\u{E9}",
]

private func hostileStrings(count: Int, seed: UInt64) -> [String] {
    var generator = SplitMix64(seed: seed)
    return (0..<count).map { _ in
        var scalars = String.UnicodeScalarView()
        for _ in 0..<Int.random(in: 0...24, using: &generator) {
            let scalar = hostileScalars.randomElement(using: &generator) ?? "a"
            scalars.append(scalar)
            if scalar == "'", Bool.random(using: &generator) {
                scalars.append(["\u{301}", "\u{FE0F}", "\u{200D}"].randomElement(using: &generator) ?? "\u{301}")
            }
        }
        return String(scalars)
    }
}

private let fixedStrings = ["", "'", "''", "'\u{301}", "a'b", "\n", "\r\n", "\t", "\\", "$HOME", "`id`", "$(id)", "!!", "*", "\u{10FFFF}"]

private func printed(_ value: String, shell: String) throws -> [UInt8] {
    let process = try ProcessLauncher.process(for: .userAuthored(
        executable: URL(fileURLWithPath: shell),
        arguments: ["-c", "printf %s " + (try ShellQuoting.singleQuoted(value))],
        environment: ["LANG": "en_US.UTF-8"]
    ))
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Array(data)
}

struct ShellQuotingTests {
    @Test("Every quoted word reads back as Process hands it over, in each POSIX shell", arguments: [
        "/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh",
    ].filter { FileManager.default.isExecutableFile(atPath: $0) })
    func roundTripsThroughShell(shell: String) throws {
        for value in fixedStrings + hostileStrings(count: 150, seed: 0x5EED_B5) {
            #expect(try printed(value, shell: shell) == ProcessLauncher.launchedBytes(of: value), "\(value.debugDescription)")
        }
    }

    @Test("A quote a combining mark follows is still closed and escaped")
    func quoteFollowedByMark() throws {
        #expect(try ShellQuoting.singleQuoted("a'\u{301}b") == "'a'\\''\u{301}b'")
    }

    @Test("A NUL is refused, since no shell word can carry it")
    func nulIsRefused() {
        #expect(throws: ProcessLaunchError.nulCharacter) { try ShellQuoting.singleQuoted("a\u{0}b") }
    }

    @Test("A display word is bare only when nothing in it hides where it ends", arguments: [
        ("ssh", "ssh"),
        ("-L", "-L"),
        ("127.0.0.1:5432", "127.0.0.1:5432"),
        ("user@host", "user@host"),
        ("", "''"),
        ("two words", "'two words'"),
        ("a;b", "'a;b'"),
        ("it's", "'it'\\''s'"),
        ("$(id)", "'$(id)'"),
        ("café", "'café'"),
        ("{port}", "'{port}'"),
        ("a{b,c}", "'a{b,c}'"),
        ("\u{202E}x", "$'\\xE2\\x80\\xAEx'"),
        ("it's\n", "$'it\\'s\\x0A'"),
        ("a\u{0}b", "$'a\\x00b'"),
    ])
    func displayWord(input: String, expected: String) {
        #expect(ShellQuoting.displayWord(input) == expected)
    }
}
