import Foundation
import TableProGoogleCloud
import TableProTestSupport
import Testing

private final class ScriptedHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let script = ScriptedHTTP.script(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        script.play(to: self)
    }

    override func stopLoading() {
        ScriptedHTTP.script(for: request)?.stopped()
    }
}

// One host per script, so cases running at once never share one.
private final class ScriptedHTTP: @unchecked Sendable {
    enum Ending {
        case finish
        case fail(URLError.Code)
        case hold
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: ScriptedHTTP] = [:]

    let session: URLSession
    let url: URL
    private let status: Int
    private let chunks: [Data]
    private let ending: Ending
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0

    init(status: Int = 200, chunks: [Data] = [], ending: Ending = .finish) throws {
        let host = "\(UUID().uuidString.lowercased()).scripted.test"
        url = try #require(URL(string: "https://\(host)/q"))
        self.status = status
        self.chunks = chunks
        self.ending = ending
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedHTTPProtocol.self]
        session = URLSession(configuration: configuration)
        Self.registryLock.withLock { Self.registry[host] = self }
    }

    static func script(for request: URLRequest) -> ScriptedHTTP? {
        guard let host = request.url?.host else { return nil }
        return registryLock.withLock { registry[host] }
    }

    var starts: Int {
        lock.withLock { startCount }
    }

    var stops: Int {
        lock.withLock { stopCount }
    }

    func read(limit: Int) async throws -> (Data, URLResponse) {
        try await BoundedHTTPRead.data(for: URLRequest(url: url), session: session, limit: limit)
    }

    func play(to loader: URLProtocol) {
        lock.withLock { startCount += 1 }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            loader.client?.urlProtocol(loader, didFailWithError: URLError(.badServerResponse))
            return
        }
        loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            loader.client?.urlProtocol(loader, didLoad: chunk)
        }
        switch ending {
        case .finish:
            loader.client?.urlProtocolDidFinishLoading(loader)
        case .fail(let code):
            loader.client?.urlProtocol(loader, didFailWithError: URLError(code))
        case .hold:
            break
        }
    }

    func stopped() {
        lock.withLock { stopCount += 1 }
    }

    func waitUntilNoTaskIsLeft() async throws {
        try await waitUntil { await session.allTasks.isEmpty }
    }
}

private final class SendCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func add() {
        lock.withLock { count += 1 }
    }
}

private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct BoundedHTTPReadTests {
    private static let kibibyte = 1_024

    @Test("A body within the limit is read whole, with its status")
    func bodyWithinTheLimit() async throws {
        let script = try ScriptedHTTP(status: 400, chunks: [Data("{\"ok\":".utf8), Data("true}".utf8)])

        let (data, response) = try await script.read(limit: 11)

        #expect(data == Data("{\"ok\":true}".utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        try await script.waitUntilNoTaskIsLeft()
    }

    @Test("Bytes past the limit end the read while the server still sends, and cancel the transfer")
    func bodyPastTheLimit() async throws {
        let chunk = Data(repeating: 0x78, count: 64 * Self.kibibyte)
        let script = try ScriptedHTTP(chunks: [chunk, chunk, chunk], ending: .hold)

        await #expect(throws: BoundedHTTPRead.BodyTooLarge(limit: 100 * Self.kibibyte)) {
            _ = try await script.read(limit: 100 * Self.kibibyte)
        }
        try await waitUntil { script.stops == 1 }
        try await script.waitUntilNoTaskIsLeft()
    }

    @Test("A caller cancelled before the read starts sends nothing and leaves no task")
    func cancelledBeforeStart() async throws {
        let script = try ScriptedHTTP(chunks: [Data("{}".utf8)])
        let gate = AsyncGate()
        let read = Task {
            await gate.wait()
            return try await script.read(limit: Self.kibibyte)
        }
        read.cancel()
        await gate.open()

        let error = await #expect(throws: URLError.self) { _ = try await read.value }
        #expect(error?.code == .cancelled)
        #expect(script.starts == 0)
        #expect(await script.session.allTasks.isEmpty)
    }

    @Test("Cancelling a running read ends it at once and cancels the transfer")
    func cancelledWhileRunning() async throws {
        let script = try ScriptedHTTP(ending: .hold)
        let read = Task { try await script.read(limit: Self.kibibyte) }
        try await waitUntil { script.starts == 1 }

        read.cancel()

        let error = await #expect(throws: URLError.self) { _ = try await read.value }
        #expect(error?.code == .cancelled)
        try await waitUntil { script.stops == 1 }
        try await script.waitUntilNoTaskIsLeft()
    }

    @Test("A transfer that fails ends the read with its error")
    func transferFails() async throws {
        let script = try ScriptedHTTP(chunks: [Data("{".utf8)], ending: .fail(.networkConnectionLost))

        let error = await #expect(throws: URLError.self) { _ = try await script.read(limit: Self.kibibyte) }

        #expect(error?.code == .networkConnectionLost)
    }

    @Test("A body the server takes whole is reported sent once")
    func bodyReportedSentOnce() async throws {
        let responder = try LoopbackHTTPResponder { _ in LoopbackResponse(status: 200, body: "{}") }
        try await responder.start()
        defer { responder.stop() }
        let session = URLSession(configuration: .ephemeral, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: responder.url("/q"))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"query":"SELECT 1"}"#.utf8)
        let sent = SendCount()

        let (data, _) = try await BoundedHTTPRead.data(
            for: request,
            session: session,
            limit: Self.kibibyte,
            onBodySent: { sent.add() }
        )

        #expect(data == Data("{}".utf8))
        #expect(sent.value == 1)
    }

    @Test("The session's own delegate still refuses a redirect")
    func sessionDelegateRefusesRedirects() async throws {
        let responder = try LoopbackHTTPResponder { request in
            request.path == "/q"
                ? LoopbackResponse(status: 302, headers: ["Location": "/elsewhere"])
                : LoopbackResponse(status: 200, body: "followed")
        }
        try await responder.start()
        defer { responder.stop() }
        let session = URLSession(
            configuration: .ephemeral,
            delegate: RedirectRefusingDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (data, response) = try await BoundedHTTPRead.data(
            for: URLRequest(url: responder.url("/q")),
            session: session,
            limit: Self.kibibyte
        )

        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(data.isEmpty)
        #expect(responder.requests.map(\.path) == ["/q"])
    }
}
