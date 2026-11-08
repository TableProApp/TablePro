import Foundation
@testable import TableProCommandLine
import TableProMCP
import Testing

struct CLITerminalTextTests {
    @Test("A message keeps its line breaks and tabs and shows every other control character")
    func messageEscaping() {
        #expect(CLITerminalText.message("plain\ttext\nnext") == "plain\ttext\nnext")
        #expect(CLITerminalText.message("a\u{1B}[2Jb\u{07}\r\u{9B}") == "a\\x1B[2Jb\\x07\\x0D\\x9B")
        #expect(CLITerminalText.message("日本語 \\ ok") == "日本語 \\ ok")
    }

    @Test("Width counts terminal cells, in any process locale", arguments: [
        ("abc", 3),
        ("日本語", 6),
        ("한국", 4),
        ("😀", 2),
        ("e\u{301}", 1),
        ("👨\u{200D}👩\u{200D}👧", 2),
        ("🇯🇵", 2),
        ("❤\u{FE0F}", 2),
        ("Ａ", 2),
        ("", 0)
    ])
    func width(text: String, cells: Int) {
        #expect(CLITerminalText.width(of: text) == cells)
    }

    @Test("Standard error lines are escaped even when the text comes from TablePro")
    func writeErrorEscapes() {
        let console = RecordingConsole()
        let environment = CLIEnvironment(
            console: console,
            terminal: CLITerminal(standardInput: false, standardOutput: false, standardError: true),
            tokenStore: MemoryTokenStore(nil),
            app: CLIHostApp(url: nil, version: nil, bundleIdentifier: nil),
            openServer: { throw CLIFailure(.failure, "unused") },
            findServer: { .notRunning },
            pair: { _ in "" },
            openTargets: { _ in },
            readStandardInput: { "" },
            readFile: { _ in "" },
            fileExists: { _ in false },
            currentDirectory: workDirectory
        )
        CLISession(environment: environment).writeError("tablepro: \u{1B}]0;title\u{07}")
        #expect(console.errors == "tablepro: \\x1B]0;title\\x07\n")
    }
}
