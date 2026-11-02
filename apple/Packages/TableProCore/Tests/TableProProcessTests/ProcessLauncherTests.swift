import Foundation
@testable import TableProProcess
import Testing

private let printf = URL(fileURLWithPath: "/usr/bin/printf")

private func output(of command: ProcessCommand) throws -> (status: Int32, stdout: Data) {
    let process = try ProcessLauncher.process(for: command)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

private func text(_ data: Data) -> String {
    String(bytes: data, encoding: .utf8) ?? ""
}

struct ProcessLauncherTests {
    @Test("A NUL in an argument, a variable or its name is refused instead of ending the app", arguments: [
        ProcessCommand(executable: printf, arguments: ["%s", "abc\u{0}def"], environment: [:]),
        ProcessCommand(executable: printf, arguments: ["x"], environment: ["A": "b\u{0}c"]),
        ProcessCommand(executable: printf, arguments: ["x"], environment: ["A\u{0}B": "c"]),
    ])
    func nulIsRefused(command: ProcessCommand) {
        #expect(throws: ProcessLaunchError.nulCharacter) { try ProcessLauncher.process(for: command) }
    }

    @Test("A relative or non-file executable is refused, since Process would look in the current folder")
    func executableMustBeAbsolute() {
        #expect(throws: ProcessLaunchError.self) {
            try ProcessLauncher.process(for: ProcessCommand(executable: URL(fileURLWithPath: "printf"), environment: [:]))
        }
        #expect(throws: ProcessLaunchError.self) {
            try ProcessLauncher.process(for: ProcessCommand(executable: URL(string: "https://example.com/tool")!, environment: [:]))
        }
    }

    @Test("An app-authored command never names a shell or env", arguments: ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env"])
    func shellIsRefused(path: String) {
        let command = ProcessCommand(executable: URL(fileURLWithPath: path), arguments: ["-c", "true"], environment: [:])
        #expect(throws: ProcessLaunchError.shellNotAllowed(path)) { try ProcessLauncher.process(for: command) }
    }

    @Test("Text the user wrote still runs in their shell")
    func userShellRuns() throws {
        let result = try output(of: .userShell("printf %s \"$GREETING\"", shell: .sh, environment: ["GREETING": "hi there"]))
        #expect(result.status == 0)
        #expect(text(result.stdout) == "hi there")
    }

    #if canImport(Darwin)
    // A user field `deploy‵touch …‵` passes every check on the Swift string, then reaches `sh -c` as backticks.
    @Test("A value macOS would rewrite into shell punctuation is refused", arguments: [
        "test deploy\u{1FEF}touch /tmp/pwned\u{1FEF} = deploy",
        "nc -z db\u{37E}id 22",
    ])
    func rewrittenPunctuationIsRefused(script: String) {
        #expect(throws: ProcessLaunchError.rewrittenOnLaunch(script)) {
            try ProcessLauncher.process(for: .userShell(script, shell: .sh, environment: [:]))
        }
    }

    @Test("Data handed to a tool that reads no shell syntax keeps a Greek question mark")
    func appAuthoredDataKeepsGreekPunctuation() throws {
        let result = try output(of: ProcessCommand(executable: printf, arguments: ["%s", "Τι\u{37E}"], environment: ["V": "x\u{1FEF}"]))
        #expect(result.status == 0)
        #expect(text(result.stdout) == "Τι;")
    }
    #endif

    @Test("Accented, CJK and symbol text still launches", arguments: ["café", "Tiếng Việt", "가나다", "Å", "\u{FEFF}", "a ≠ b"])
    func nonASCIIStillLaunches(value: String) throws {
        let result = try output(of: ProcessCommand(executable: printf, arguments: ["%s", value], environment: [:]))
        #expect(result.status == 0)
        #expect(Array(result.stdout) == ProcessLauncher.launchedBytes(of: value))
    }

    @Test("A variable name with `=` is refused, since the child would read another name and value")
    func environmentNameWithEqualsIsRefused() {
        let command = ProcessCommand(executable: printf, arguments: ["x"], environment: ["A=B": "c"])
        #expect(throws: ProcessLaunchError.invalidEnvironmentName("A=B")) { try ProcessLauncher.process(for: command) }
    }

    @Test("The child runs in `/` unless the caller names a folder, never in the app's own")
    func currentDirectoryDefaultsToRoot() throws {
        let result = try output(of: .userShell("pwd", shell: .sh, environment: [:]))
        #expect(text(result.stdout) == "/\n")
        let folder = FileManager.default.temporaryDirectory
        let named = try output(of: .userShell("pwd -P", shell: .sh, environment: [:], currentDirectory: folder))
        let physical = try #require(realpath(folder.path, nil))
        defer { free(physical) }
        #expect(text(named.stdout) == String(cString: physical) + "\n")
    }

    @Test("The child gets exactly the environment it was given")
    func environmentIsExplicit() throws {
        let result = try output(of: ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/env"), environment: ["ONLY": "1"])
            .asUserAuthored)
        #expect(text(result.stdout) == "ONLY=1\n")
    }
}

private extension ProcessCommand {
    var asUserAuthored: ProcessCommand {
        .userAuthored(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
    }
}
