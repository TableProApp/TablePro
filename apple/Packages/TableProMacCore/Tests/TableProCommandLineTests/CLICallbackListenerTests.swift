import Foundation
import TableProCommandLine
import TableProMCP
import Testing

struct CLICallbackListenerTests {
    @Test("The listener answers stray requests and hands back the code the browser delivers")
    func listenerRoundTrip() async throws {
        let listener = CLICallbackListener(state: "s1")
        defer { listener.stop() }
        let port = try await listener.start()
        #expect(port > 0)

        let session = URLSession(configuration: .ephemeral)
        let stray = try #require(URL(string: "http://127.0.0.1:\(port)/favicon.ico"))
        let (_, strayResponse) = try await session.data(from: stray)
        #expect((strayResponse as? HTTPURLResponse)?.statusCode == 404)

        let callback = try #require(URL(string: "http://127.0.0.1:\(port)\(CLIPairingRequest.callbackPath)?code=c-1&state=s1"))
        let (body, response) = try await session.data(from: callback)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: body, encoding: .utf8)?.contains("You can close this tab") == true)

        #expect(await listener.waitForCallback(timeout: .seconds(5)) == .approved(code: "c-1"))
    }

    @Test("A listener nobody calls gives up")
    func listenerTimeout() async throws {
        let listener = CLICallbackListener(state: "s1")
        defer { listener.stop() }
        _ = try await listener.start()
        #expect(await listener.waitForCallback(timeout: .milliseconds(50)) == nil)
    }
}
