import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

struct AgentCLIProcessTests {
    static let perl = "/usr/bin/perl"

    static var hasPerl: Bool {
        FileManager.default.isExecutableFile(atPath: perl)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [String] = []

        func append(_ line: String) {
            lock.withLock { received.append(line) }
        }

        var all: [String] {
            lock.withLock { received }
        }
    }

    private let shellLaunch = AgentCLILaunch(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exit 0"],
        environment: [:]
    )

    private static func perlLaunch(_ script: String) -> AgentCLILaunch {
        AgentCLILaunch(executable: URL(fileURLWithPath: perl), arguments: ["-e", script], environment: [:])
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
        "Every stdout line arrives while the child holds stderr open and never writes to it",
        .enabled(if: AgentCLIProcessTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func manyLinesArriveBesideSilentStderr() async throws {
        let stream = AgentCLIProcess(label: "test").streamLines(
            Self.perlLaunch(#"$| = 1; print "line $_\n" for 1 .. 30000;"#)
        )
        var lines: [String] = []
        for try await line in stream {
            lines.append(line)
        }
        #expect(lines == (1 ... 30_000).map { "line \($0)" })
    }

    @Test(
        "A line arrives while the child keeps running, and ending the stream stops the child",
        .enabled(if: AgentCLIProcessTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func lineArrivesBeforeTheChildExits() async throws {
        let received = Lines()
        let stream = AgentCLIProcess(label: "test").streamLines(
            Self.perlLaunch(#"$| = 1; print "$$\n"; select(undef, undef, undef, 0.3); print "running\n"; sleep 30;"#)
        )
        let consumer = Task {
            for try await line in stream {
                received.append(line)
            }
        }
        defer { consumer.cancel() }

        try await waitUntil { received.all.count == 2 }
        #expect(received.all.last == "running")
        let child = try #require(received.all.first.flatMap { pid_t($0) })

        consumer.cancel()
        _ = await consumer.result
        try await waitUntil { kill(child, 0) != 0 }
    }

    @Test(
        "A last line without a newline still arrives",
        .enabled(if: AgentCLIProcessTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func unterminatedLastLineArrives() async throws {
        var lines: [String] = []
        for try await line in AgentCLIProcess(label: "test").streamLines(Self.perlLaunch(#"print "first\nlast";"#)) {
            lines.append(line)
        }
        #expect(lines == ["first", "last"])
    }

    @Test(
        "A run returns everything a child writes past the pipe's capacity",
        .enabled(if: AgentCLIProcessTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func runReturnsOutputPastPipeCapacity() async throws {
        let result = try await AgentCLIProcess(label: "test").run(
            Self.perlLaunch(#"$| = 1; print "x" x 200000; print STDERR "done"; exit 3;"#)
        )
        #expect(result.code == 3)
        #expect(result.output == String(repeating: "x", count: 200_000) + "done")
    }

    @Test(
        "Cancelling a run stops the child, even when the cancel lands before launch",
        .enabled(if: AgentCLIProcessTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func cancelledRunStopsTheChild() async {
        let cancelled = AsyncGate()
        let run = Task {
            await cancelled.wait()
            return try await AgentCLIProcess(label: "test").run(Self.perlLaunch("sleep 30"))
        }
        run.cancel()
        await cancelled.open()

        let ended = await BoundedCall.result { () async -> Bool in
            _ = try? await run.value
            return true
        }
        #expect(ended == true)
    }

    @Test("Lines end at LF alone, lose a trailing CR, skip empty lines and keep a character split across chunks")
    func splitterJoinsChunks() {
        var splitter = AgentCLIProcess.LineSplitter()
        let accented = Array("\u{E9}\n".utf8)
        let chunks = [
            Data("a\r\nb".utf8),
            Data("c\n\n\r\n".utf8),
            Data(accented.prefix(1)),
            Data(accented.dropFirst()),
            Data("x\u{2028}y\r\n".utf8)
        ]

        let lines = chunks.map { splitter.append($0) }

        #expect(lines == [["a"], ["bc"], [], ["\u{E9}"], ["x\u{2028}y"]])
    }

    @Test("A line that is not UTF-8 is dropped, and a tail without a newline comes out at the end")
    func splitterDropsInvalidLinesAndFlushesTheTail() {
        var splitter = AgentCLIProcess.LineSplitter()

        let lines = splitter.append(Data([0x6F, 0xFF, 0x6B, 0x0A]) + Data("ok\n".utf8) + Data("tail".utf8))
        let tail = splitter.finish()
        let afterTail = splitter.finish()

        #expect(lines == ["ok"])
        #expect(tail == ["tail"])
        #expect(afterTail.isEmpty)
    }
}
