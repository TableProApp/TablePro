import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

struct LSPTransportBrokenPipeTests {
    static let perl = "/usr/bin/perl"

    static var hasPerl: Bool {
        FileManager.default.isExecutableFile(atPath: perl)
    }

    // A server on its way out: it stops reading, asks the client something, then says it has stopped.
    private static let closingServer = #"""
    close STDIN; $| = 1;
    for my $body ('{"jsonrpc":"2.0","id":7,"method":"workspace/configuration","params":{}}',
                  '{"jsonrpc":"2.0","method":"test/inputClosed"}') {
        print "Content-Length: " . length($body) . "\r\n\r\n" . $body;
    }
    sleep 30;
    """#

    @Test(
        "A server that stopped reading fails the request instead of ending the app",
        .enabled(if: LSPTransportBrokenPipeTests.hasPerl),
        .timeLimit(.minutes(1))
    )
    func closedInputFailsTheRequest() async throws {
        let transport = LSPTransport()
        let inputClosed = AsyncGate()
        await transport.onNotification(method: "test/inputClosed") { _ in
            Task { await inputClosed.open() }
        }
        try await transport.start(executablePath: Self.perl, arguments: ["-e", Self.closingServer])
        await inputClosed.wait()

        let error = await #expect(throws: (any Error).self) {
            _ = try await transport.sendRequest(method: "test/afterClose", params: EmptyLSPParams())
        }
        await transport.stop()

        let failure = error.map { $0 as NSError }
        let posix = failure?.domain == NSPOSIXErrorDomain
            ? failure
            : failure?.underlyingErrors.first.map { $0 as NSError }
        #expect(posix?.code == Int(EPIPE))
    }
}
