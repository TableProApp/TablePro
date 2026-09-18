import Foundation
import TableProGoogleCloud

public final class SpannerRESTClient: Sendable {
    static let defaultRetryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

    let settings: SpannerConnectionSettings
    let transport: any SpannerTransport
    let tokenProvider: (any GoogleAccessTokenProviding)?
    let retryDelays: [Duration]

    public convenience init(
        settings: SpannerConnectionSettings,
        transport: any SpannerTransport,
        tokenProvider: (any GoogleAccessTokenProviding)?
    ) {
        self.init(
            settings: settings,
            transport: transport,
            tokenProvider: tokenProvider,
            retryDelays: Self.defaultRetryDelays
        )
    }

    init(
        settings: SpannerConnectionSettings,
        transport: any SpannerTransport,
        tokenProvider: (any GoogleAccessTokenProviding)?,
        retryDelays: [Duration]
    ) {
        self.settings = settings
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.retryDelays = retryDelays
    }

    public func databaseDialect() async throws -> String? {
        let call = try SpannerHTTPCall(method: .get, url: settings.databaseURL(), replaySafe: true)
        let database = try await decode(SpannerDatabaseResponse.self, from: perform(call))
        return database.databaseDialect
    }

    public func createSession(multiplexed: Bool) async throws -> String {
        let body = SpannerCreateSessionBody(session: .init(multiplexed: multiplexed ? true : nil, labels: ["app": "tablepro"]))
        let call = try SpannerHTTPCall(
            method: .post,
            url: settings.databaseURL(suffix: "sessions"),
            body: encode(body),
            replaySafe: true
        )
        let session = try await decode(SpannerNamedResource.self, from: perform(call))
        guard !session.name.isEmpty else { throw SpannerTransportError.invalidResponse }
        return session.name
    }

    public func deleteSession(_ name: String) async throws {
        let call = try SpannerHTTPCall(method: .delete, url: settings.resourceURL(name), replaySafe: true)
        _ = try await perform(call)
    }

    public func executeSql(session: String, _ request: SpannerExecuteSqlRequest) async throws -> SpannerResultSet {
        let call = try SpannerHTTPCall(
            method: .post,
            url: settings.resourceURL(session, verb: "executeSql"),
            body: encode(request),
            replaySafe: request.isReplaySafe
        )
        return try SpannerResultSet(foundationObject: SpannerFoundationJSON.object(await perform(call)))
    }

    public func executeStreamingSql(
        session: String,
        _ request: SpannerExecuteSqlRequest
    ) async throws -> AsyncThrowingStream<SpannerStreamEvent, Error> {
        let call = try SpannerHTTPCall(
            method: .post,
            url: settings.resourceURL(session, verb: "executeStreamingSql"),
            body: encode(request),
            replaySafe: false
        )
        let (response, chunks) = try await openStream(call)
        return Self.events(from: chunks, httpStatus: response.statusCode)
    }

    public func beginTransaction(session: String) async throws -> String {
        let call = try SpannerHTTPCall(
            method: .post,
            url: settings.resourceURL(session, verb: "beginTransaction"),
            body: encode(SpannerBeginTransactionBody()),
            replaySafe: false
        )
        let transaction = try await decode(SpannerTransactionResponse.self, from: perform(call))
        guard let identifier = transaction.id, !identifier.isEmpty else {
            throw SpannerTransportError.invalidResponse
        }
        return identifier
    }

    public func commit(session: String, transactionId: String) async throws {
        try await finishTransaction(session: session, transactionId: transactionId, verb: "commit")
    }

    public func rollback(session: String, transactionId: String) async throws {
        try await finishTransaction(session: session, transactionId: transactionId, verb: "rollback")
    }

    public func updateDdl(_ statements: [String]) async throws -> SpannerOperation {
        let call = try SpannerHTTPCall(
            method: .patch,
            url: settings.databaseURL(suffix: "ddl"),
            body: encode(SpannerUpdateDdlBody(statements: statements)),
            replaySafe: false
        )
        return try await decodeOperation(perform(call))
    }

    public func operation(named name: String) async throws -> SpannerOperation {
        let call = try SpannerHTTPCall(method: .get, url: settings.resourceURL(name), replaySafe: true)
        return try await decodeOperation(perform(call))
    }

    public func databaseDDL() async throws -> [String] {
        let call = try SpannerHTTPCall(method: .get, url: settings.databaseURL(suffix: "ddl"), replaySafe: true)
        return try await decode(SpannerDDLResponse.self, from: perform(call)).statements
    }

    public func close() async {
        await transport.close()
    }

    private func finishTransaction(session: String, transactionId: String, verb: String) async throws {
        let call = try SpannerHTTPCall(
            method: .post,
            url: settings.resourceURL(session, verb: verb),
            body: encode(SpannerTransactionIdBody(transactionId: transactionId)),
            replaySafe: true
        )
        _ = try await perform(call)
    }

    private func decodeOperation(_ data: Data) throws -> SpannerOperation {
        let operation = try decode(SpannerOperationResponse.self, from: data)
        guard !operation.name.isEmpty else { throw SpannerTransportError.invalidResponse }
        return SpannerOperation(
            name: operation.name,
            done: operation.done,
            error: operation.error.map { SpannerAPIError(httpStatus: 200, payload: $0) }
        )
    }
}
