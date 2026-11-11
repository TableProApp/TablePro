import Foundation
@testable import TablePro
import Testing

struct AgentCLIProcessTests {
    private let shellLaunch = AgentCLILaunch(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exit 0"],
        environment: [:]
    )

    static let perl = "/usr/bin/perl"

    static var hasPerl: Bool {
        FileManager.default.isExecutableFile(atPath: perl)
    }

    private static func perlLaunch(_ script: String) -> AgentCLILaunch {
        AgentCLILaunch(executable: URL(fileURLWithPath: perl), arguments: ["-e", script], environment: [:])
    }

    // Two lines half a second apart from a tool that then keeps running with stderr open and quiet.
    private static let twoLinesThenWait =
        #"$| = 1; print "one\n"; select(undef, undef, undef, 0.5); print "two\n"; sleep 120;"#

    private static func firstLines(_ count: Int, of script: String) async throws -> [String] {
        var received: [String] = []
        for try await line in AgentCLIProcess(label: "test").streamLines(perlLaunch(script)) {
            received.append(line)
            if received.count == count { break }
        }
        return received
    }

    @Test("A launch the launcher refuses fails as a launch failure instead of running")
    func refusedLaunchFailsTheRun() async {
        await #expect(throws: AgentCLIError.self) {
            _ = try await AgentCLIProcess(label: "claude").run(shellLaunch)
        }
    }

    @Test("A launch the launcher refuses ends the line stream with a launch failure")
    func refusedLaunchEndsTheStream() async {
        await #expect(throws: AgentCLIError.self) {
            for try await _ in AgentCLIProcess(label: "claude").streamLines(shellLaunch) {}
        }
    }

    @Test(
        "Each line arrives while the tool still runs",
        .enabled(if: AgentCLIProcessTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func linesStreamBeforeExit() async throws {
        #expect(try await Self.firstLines(2, of: Self.twoLinesThenWait) == ["one", "two"])
    }

    @Test(
        "Output larger than the pipe buffer is read through while the tool still runs",
        .enabled(if: AgentCLIProcessTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func outputPastThePipeBuffer() async throws {
        let script = #"$| = 1; print(("x" x 99) . "\n") for 1 .. 3000; sleep 120;"#
        var count = 0
        for try await line in AgentCLIProcess(label: "test").streamLines(Self.perlLaunch(script)) {
            #expect(line.count == 99)
            count += 1
            if count == 3000 { break }
        }
        #expect(count == 3000)
    }

    @Test(
        "The stream ends at end of output and keeps a last line with no newline",
        .enabled(if: AgentCLIProcessTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func lastLineWithoutNewline() async throws {
        var received: [String] = []
        for try await line in AgentCLIProcess(label: "test").streamLines(Self.perlLaunch(#"print "a\r\n\nb";"#)) {
            received.append(line)
        }
        #expect(received == ["a", "b"])
    }

    @Test(
        "An idle language server does not hold the chat's output",
        .enabled(if: AgentCLIProcessTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func idleLanguageServerDoesNotHoldTheStream() async throws {
        let transport = LSPTransport()
        try await transport.start(executablePath: Self.perl, arguments: ["-e", "sleep 120"])
        let received: [String]
        do {
            received = try await Self.firstLines(2, of: Self.twoLinesThenWait)
        } catch {
            await transport.stop()
            throw error
        }
        await transport.stop()
        #expect(received == ["one", "two"])
    }
}
