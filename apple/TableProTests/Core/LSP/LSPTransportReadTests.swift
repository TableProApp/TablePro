import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

struct LSPTransportReadTests {
    static let perl = "/usr/bin/perl"

    static var hasPerl: Bool {
        FileManager.default.isExecutableFile(atPath: perl)
    }

    // The pause lets the test's AsyncBytes read park before the second message is written.
    private static let pausingServer = #"""
    $| = 1;
    for my $method ('test/first', 'test/second') {
        my $body = '{"jsonrpc":"2.0","method":"' . $method . '"}';
        print "Content-Length: " . length($body) . "\r\n\r\n" . $body;
        select(undef, undef, undef, 0.3);
    }
    sleep 30;
    """#

    @Test(
        "Server messages arrive while an AsyncBytes read elsewhere in the app waits on a quiet pipe",
        .enabled(if: LSPTransportReadTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func messagesArriveBesideAParkedAsyncBytesRead() async throws {
        let quiet = Pipe()
        defer { withExtendedLifetime(quiet) {} }
        let quietOutput = quiet.fileHandleForReading
        let parked = Task {
            for try await _ in quietOutput.bytes {}
        }

        let transport = LSPTransport()
        let first = AsyncGate()
        let second = AsyncGate()
        await transport.onNotification(method: "test/first") { _ in
            Task { await first.open() }
        }
        await transport.onNotification(method: "test/second") { _ in
            Task { await second.open() }
        }
        try await transport.start(executablePath: Self.perl, arguments: ["-e", Self.pausingServer])

        let arrived: Void? = await HeldOpenWriter(quiet.fileHandleForWriting).finished {
            await first.wait()
            await second.wait()
        }
        await transport.stop()

        try #require(arrived != nil)
        try quiet.fileHandleForWriting.close()
        _ = await parked.result
    }
}
