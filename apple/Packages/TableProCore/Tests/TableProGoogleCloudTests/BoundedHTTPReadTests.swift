import Foundation
import TableProGoogleCloud
import TableProTestSupport
import Testing

struct BoundedHTTPReadTests {
    private func serve(_ body: String, status: Int = 200) async throws -> LoopbackHTTPResponder {
        let responder = try LoopbackHTTPResponder { _ in LoopbackResponse(status: status, body: body) }
        try await responder.start()
        return responder
    }

    @Test("A body within the limit is read whole, with its status")
    func bodyWithinTheLimit() async throws {
        let responder = try await serve("{\"ok\":true}", status: 400)
        defer { responder.stop() }

        let (data, response) = try await BoundedHTTPRead.data(
            for: URLRequest(url: responder.url("/q")), session: URLSession(configuration: .ephemeral), limit: 11
        )

        #expect(data == Data("{\"ok\":true}".utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
    }

    @Test("A body past the limit stops the read")
    func bodyPastTheLimit() async throws {
        let responder = try await serve(String(repeating: "x", count: 512 * 1_024))
        defer { responder.stop() }

        await #expect(throws: BoundedHTTPRead.BodyTooLarge(limit: 64 * 1_024)) {
            _ = try await BoundedHTTPRead.data(
                for: URLRequest(url: responder.url("/q")),
                session: URLSession(configuration: .ephemeral),
                limit: 64 * 1_024
            )
        }
    }

    @Test("A caller already cancelled sends nothing")
    func cancelledCallerSendsNothing() async throws {
        let responder = try await serve("{}")
        defer { responder.stop() }
        let gate = AsyncGate()
        let read = Task {
            await gate.wait()
            return try await BoundedHTTPRead.data(
                for: URLRequest(url: responder.url("/q")), session: URLSession(configuration: .ephemeral), limit: 1_024
            )
        }
        read.cancel()
        await gate.open()

        await #expect(throws: URLError.self) { _ = try await read.value }
        #expect(responder.requests.isEmpty)
    }
}
