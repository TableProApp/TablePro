import Foundation
import TableProPluginKit
import Testing

struct DynamoDBClientTests {
    private static let exampleDate = Date(timeIntervalSince1970: 1_440_938_160)

    private static let throttled = DynamoDBClientTestTransport.Reply.http(
        status: 400,
        body: #"{"__type":"com.amazonaws.dynamodb.v20120810#ProvisionedThroughputExceededException","message":"Rate exceeded"}"#
    )
    private static let internalError = DynamoDBClientTestTransport.Reply.http(
        status: 500, body: #"{"__type":"com.amazonaws.dynamodb.v20120810#InternalServerError","message":"Internal error"}"#
    )
    private static let expiredToken = DynamoDBClientTestTransport.Reply.http(
        status: 400, body: #"{"__type":"com.amazonaws.dynamodb.v20120810#ExpiredTokenException","message":"expired"}"#
    )
    private static let signatureExpired = DynamoDBClientTestTransport.Reply.http(
        status: 400,
        body: #"{"__type":"com.amazonaws.dynamodb.v20120810#InvalidSignatureException","#
            + #""message":"Signature expired: 20150830T123600Z is now earlier than 20150830T124100Z"}"#,
        headers: ["Date": "Sun, 30 Aug 2015 12:46:00 GMT"]
    )
    private static let tableNames = DynamoDBClientTestTransport.Reply.http(status: 200, body: #"{"TableNames":["Orders"]}"#)

    private static func makeClient(
        _ transport: DynamoDBClientTestTransport,
        sleeps: DynamoDBClientSleepLog = DynamoDBClientSleepLog(),
        sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) throws -> DynamoDBClient {
        let endpoint = try DynamoDBEndpoint.resolve(fields: ["awsAuthMethod": "local"], profileRegion: { _ in nil })
        let credentials = DynamoDBCredentialsProvider(fields: ["awsAuthMethod": "local"], username: "", password: "")
        let fixedNow = exampleDate
        return DynamoDBClient(
            endpoint: endpoint,
            credentials: credentials,
            transport: transport,
            retryPolicy: DynamoDBRetryPolicy(random: { 0 }),
            now: { fixedNow },
            sleep: sleep ?? { seconds in sleeps.record(seconds) }
        )
    }

    private static func serviceCode(of error: (any Error)?) -> String? {
        guard case .service(let service)? = error as? DynamoDBError else { return nil }
        return service.code
    }

    @Test("Throttling is retried until DynamoDB accepts the request")
    func throttlingRetriesUntilSuccess() async throws {
        let transport = DynamoDBClientTestTransport([Self.throttled, Self.throttled, Self.tableNames])
        let sleeps = DynamoDBClientSleepLog()
        let client = try Self.makeClient(transport, sleeps: sleeps)

        let response = try await client.send(.listTables, [:])

        #expect(response["TableNames"] == .array([.string("Orders")]))
        #expect(transport.requests.count == 3)
        #expect(sleeps.delays == [0, 0])
    }

    @Test("Throttling gives up after four attempts")
    func throttlingGivesUp() async throws {
        let transport = DynamoDBClientTestTransport(Array(repeating: Self.throttled, count: 6))
        let client = try Self.makeClient(transport)

        let error = await #expect(throws: DynamoDBError.self) {
            try await client.send(.updateItem, [:])
        }

        #expect(Self.serviceCode(of: error) == "ProvisionedThroughputExceededException")
        #expect(transport.requests.count == DynamoDBRetryPolicy.maximumAttempts)
    }

    @Test("A 500 on an UpdateItem is not sent again")
    func updateItemServerErrorIsNotRetried() async throws {
        let transport = DynamoDBClientTestTransport([Self.internalError, Self.tableNames])
        let client = try Self.makeClient(transport)

        let error = await #expect(throws: DynamoDBError.self) {
            try await client.send(.updateItem, ["TableName": .string("Orders")])
        }

        #expect(Self.serviceCode(of: error) == "InternalServerError")
        #expect(transport.requests.count == 1)
    }

    @Test("A 500 on a read is sent again")
    func readServerErrorIsRetried() async throws {
        let transport = DynamoDBClientTestTransport([Self.internalError, Self.tableNames])
        let client = try Self.makeClient(transport)

        _ = try await client.send(.getItem, ["TableName": .string("Orders")])

        #expect(transport.requests.count == 2)
    }

    @Test("A redirect is a configuration error, refused without a retry")
    func redirectIsRefused() async throws {
        let transport = DynamoDBClientTestTransport([
            .http(status: 307, body: "", headers: ["Location": "http://attacker.example.com/"])
        ])
        let client = try Self.makeClient(transport)

        await #expect(throws: DynamoDBError.configuration(String(
            localized: "The endpoint answered with a redirect, which DynamoDB never sends. Check the Custom Endpoint."
        ))) {
            try await client.send(.updateItem, [:])
        }
        #expect(transport.requests.count == 1)
    }

    @Test("A clock skew error moves the signing clock to the server's Date")
    func clockSkewShiftsSigningDate() async throws {
        let transport = DynamoDBClientTestTransport([Self.signatureExpired, Self.tableNames])
        let client = try Self.makeClient(transport)

        _ = try await client.send(.listTables, [:])

        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests.first?.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        #expect(requests.last?.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T124600Z")
    }

    @Test("The clock is corrected once, and a second skew error fails")
    func clockSkewCorrectsOnce() async throws {
        let transport = DynamoDBClientTestTransport([Self.signatureExpired, Self.signatureExpired, Self.tableNames])
        let client = try Self.makeClient(transport)

        let error = await #expect(throws: DynamoDBError.self) {
            try await client.send(.listTables, [:])
        }

        #expect(Self.serviceCode(of: error) == "InvalidSignatureException")
        #expect(transport.requests.count == 2)
    }

    @Test("An expired token is refreshed once, and a second expiry fails")
    func expiredTokenRefreshesOnce() async throws {
        let transport = DynamoDBClientTestTransport([Self.expiredToken, Self.expiredToken, Self.tableNames])
        let client = try Self.makeClient(transport)

        let error = await #expect(throws: DynamoDBError.self) {
            try await client.send(.updateItem, [:])
        }

        #expect(Self.serviceCode(of: error) == "ExpiredTokenException")
        #expect(transport.requests.count == 2)
    }

    @Test("Cancelling the task while it waits to retry ends with cancelled")
    func cancellingDuringSleep() async throws {
        let transport = DynamoDBClientTestTransport([Self.throttled, Self.tableNames])
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let client = try Self.makeClient(transport, sleep: { _ in
            startedContinuation.yield()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })

        let task = Task { try await client.send(.listTables, [:]) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        let result = await task.result

        guard case .failure(let error) = result else {
            Issue.record("The request finished after its task was cancelled")
            return
        }
        #expect(error as? DynamoDBError == .cancelled)
        #expect(transport.requests.count == 1)
    }

    @Test("A task cancelled before it starts sends nothing")
    func cancelledBeforeStart() async throws {
        let transport = DynamoDBClientTestTransport([Self.tableNames])
        let client = try Self.makeClient(transport)
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()

        let task = Task {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return try await client.send(.listTables, [:])
        }
        task.cancel()
        gateContinuation.yield()
        let result = await task.result

        guard case .failure(let error) = result else {
            Issue.record("A cancelled task sent its request")
            return
        }
        #expect(error as? DynamoDBError == .cancelled)
        #expect(transport.requests.isEmpty)
    }

    @Test("A cancellation the transport reports is surfaced as cancelled", arguments: [true, false])
    func transportCancellation(_ asURLError: Bool) async throws {
        let reply: DynamoDBClientTestTransport.Reply = asURLError ? .urlError(.cancelled) : .taskCancelled
        let transport = DynamoDBClientTestTransport([reply, Self.tableNames])
        let client = try Self.makeClient(transport)

        await #expect(throws: DynamoDBError.cancelled) {
            try await client.send(.listTables, [:])
        }
        #expect(transport.requests.count == 1)
    }

    @Test("A dropped connection is retried for a read and not for an UpdateItem")
    func transportFailureRetriesIdempotentOnly() async throws {
        let readTransport = DynamoDBClientTestTransport([.urlError(.networkConnectionLost), Self.tableNames])
        _ = try await Self.makeClient(readTransport).send(.scan, ["TableName": .string("Orders")])
        #expect(readTransport.requests.count == 2)

        let writeTransport = DynamoDBClientTestTransport([.urlError(.networkConnectionLost), Self.tableNames])
        let error = await #expect(throws: DynamoDBError.self) {
            try await Self.makeClient(writeTransport).send(.updateItem, ["TableName": .string("Orders")])
        }
        guard case .transport? = error else {
            Issue.record("A dropped connection was not reported as a transport error: \(String(describing: error))")
            return
        }
        #expect(writeTransport.requests.count == 1)
    }

    @Test("An empty 200 answers an empty object")
    func emptySuccessBody() async throws {
        let transport = DynamoDBClientTestTransport([.http(status: 200, body: "")])
        let response = try await Self.makeClient(transport).send(.deleteItem, [:])
        #expect(response == .object([:]))
    }

    @Test("A 200 that is not JSON is an invalid response")
    func unparsableSuccessBody() async throws {
        let transport = DynamoDBClientTestTransport([.http(status: 200, body: "<html>")])
        let error = await #expect(throws: DynamoDBError.self) {
            try await Self.makeClient(transport).send(.listTables, [:])
        }
        guard case .invalidResponse? = error else {
            Issue.record("Expected an invalid response, got \(String(describing: error))")
            return
        }
    }

    @Test("Every request is a signed POST carrying the target, the content type and the body")
    func requestShape() async throws {
        let transport = DynamoDBClientTestTransport([Self.throttled, Self.tableNames])
        let client = try Self.makeClient(transport)
        let body: [String: DynamoDBJSON] = ["Limit": .number("1")]

        _ = try await client.send(.listTables, body)

        let requests = transport.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "http://localhost:8000")
            #expect(request.value(forHTTPHeaderField: "X-Amz-Target") == "DynamoDB_20120810.ListTables")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.0")
            #expect(request.value(forHTTPHeaderField: "Host") == "localhost:8000")
            #expect(request.httpBody == DynamoDBJSON.object(body).serializedData)
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            #expect(authorization.hasPrefix(
                "AWS4-HMAC-SHA256 Credential=local/20150830/us-east-1/dynamodb/aws4_request, "
                    + "SignedHeaders=content-type;host;x-amz-date;x-amz-target, Signature="
            ))
        }
    }
}

@Suite("DynamoDB credentials provider", .serialized)
struct DynamoDBCredentialsProviderTests {
    @Test("Local auth signs with the fixed local key and needs no AWS files")
    func localCredentials() async throws {
        let provider = DynamoDBCredentialsProvider(fields: ["awsAuthMethod": "local"], username: "ignored", password: "ignored")
        let credentials = try await provider.credentials()
        #expect(credentials.accessKeyId == DynamoDBCredentialsProvider.localAccessKey)
        #expect(credentials.secretAccessKey == DynamoDBCredentialsProvider.localAccessKey)
        #expect(credentials.sessionToken == nil)
        #expect(provider.identity == "local")
    }

    @Test("Access key auth falls back to the username and password")
    func accessKeyFromUsernameAndPassword() async throws {
        let provider = DynamoDBCredentialsProvider(
            fields: ["awsAuthMethod": "credentials"], username: "AKIDEXAMPLE", password: "secret"
        )
        let credentials = try await provider.credentials()
        #expect(credentials.accessKeyId == "AKIDEXAMPLE")
        #expect(credentials.secretAccessKey == "secret")
        #expect(provider.identity == "key:AKIDEXAMPLE")
    }

    @Test("An SSO profile that does not exist throws the AWS error, not a DynamoDB error")
    func missingSSOProfileKeepsAWSError() async throws {
        let profile = "tablepro-missing-\(UUID().uuidString)"
        let provider = DynamoDBCredentialsProvider(
            fields: ["awsAuthMethod": "sso", "awsProfileName": profile], username: "", password: ""
        )

        let error = try await DynamoDBTestAWSFiles.withEmptyConfiguration {
            await #expect(throws: (any Error).self) {
                try await provider.credentials()
            }
        }

        let thrown = try #require(error)
        #expect(!(thrown is DynamoDBError))
        #expect(thrown is AWSAuthError || thrown is AWSSSOError)
        #expect(provider.identity == "profile:\(profile)")
    }

    @Test("The client passes a credential error through unwrapped and sends nothing")
    func clientPassesCredentialErrorThrough() async throws {
        let profile = "tablepro-missing-\(UUID().uuidString)"
        let transport = DynamoDBClientTestTransport([])
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsAuthMethod": "sso", "awsRegion": "us-east-1"], profileRegion: { _ in nil }
        )
        let client = DynamoDBClient(
            endpoint: endpoint,
            credentials: DynamoDBCredentialsProvider(
                fields: ["awsAuthMethod": "sso", "awsProfileName": profile], username: "", password: ""
            ),
            transport: transport,
            retryPolicy: DynamoDBRetryPolicy(random: { 0 }),
            sleep: { _ in }
        )

        let error = try await DynamoDBTestAWSFiles.withEmptyConfiguration {
            await #expect(throws: (any Error).self) {
                try await client.send(.listTables, [:])
            }
        }

        let thrown = try #require(error)
        #expect(!(thrown is DynamoDBError))
        #expect(transport.requests.isEmpty)
    }
}

private enum DynamoDBTestAWSFiles {
    static let variables = ["AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE"]

    static func withEmptyConfiguration<Value>(_ body: () async throws -> Value) async throws -> Value {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-dynamodb-aws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = variables.map { name in getenv(name).map { String(cString: $0) } }
        for name in variables {
            let file = directory.appendingPathComponent(name.lowercased())
            try Data().write(to: file)
            setenv(name, file.path, 1)
        }
        defer {
            for (name, value) in zip(variables, previous) {
                if let value {
                    setenv(name, value, 1)
                } else {
                    unsetenv(name)
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        return try await body()
    }
}

private final class DynamoDBClientTestTransport: DynamoDBTransport, @unchecked Sendable {
    enum Reply: Sendable {
        case http(status: Int, body: String, headers: [String: String] = [:])
        case urlError(URLError.Code)
        case taskCancelled
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = lock.withLock { () -> Reply? in
            recorded.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else {
            throw URLError(.resourceUnavailable)
        }
        switch reply {
        case .urlError(let code):
            throw URLError(code)
        case .taskCancelled:
            throw CancellationError()
        case .http(let status, let body, let headers):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        }
    }

    func invalidate() {}
}

private final class DynamoDBClientSleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    func record(_ seconds: TimeInterval) {
        lock.withLock { recorded.append(seconds) }
    }

    var delays: [TimeInterval] {
        lock.withLock { recorded }
    }
}
