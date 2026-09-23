import Foundation
import os
import TableProPluginKit

protocol DynamoDBTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func invalidate()
}

/// URLSession, with every redirect refused.
///
/// URLSession follows a 307 to another host by default and sends the body and
/// `X-Amz-Security-Token` along, which would carry a request past the rule that plain HTTP goes
/// only to this Mac. DynamoDB never redirects, so a redirect is an error.
final class DynamoDBURLSessionTransport: NSObject, DynamoDBTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = HttpQueryTimeout.sessionBootstrapRequestTimeout
        configuration.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DynamoDBError.invalidResponse(String(localized: "The endpoint did not answer over HTTP"))
        }
        return (data, http)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Resolves and caches the AWS credentials a connection signs with.
final class DynamoDBCredentialsProvider: @unchecked Sendable {
    static let localAccessKey = "local"

    private let fields: [String: String]
    private let method: DynamoDBAuthMethod
    private let lock = NSLock()
    private var cached: AWSCredentials?

    init(fields: [String: String], username: String, password: String) {
        var resolved = fields
        if (resolved["awsAccessKeyId"] ?? "").isEmpty, !username.isEmpty {
            resolved["awsAccessKeyId"] = username
        }
        if (resolved["awsSecretAccessKey"] ?? "").isEmpty, !password.isEmpty {
            resolved["awsSecretAccessKey"] = password
        }
        self.fields = resolved
        self.method = DynamoDBAuthMethod(fieldValue: fields["awsAuthMethod"])
    }

    var identity: String {
        switch method {
        case .local: return "local"
        case .profile, .singleSignOn: return "profile:" + (fields["awsProfileName"] ?? "default")
        case .accessKey: return "key:" + (fields["awsAccessKeyId"] ?? "")
        }
    }

    /// `AWSSSOError` and `AWSAuthError` leave here unwrapped: the app offers its SSO sign-in
    /// prompt only when it can see an `AWSSSOError`.
    func credentials(forceRefresh: Bool = false) async throws -> AWSCredentials {
        if method == .local {
            return AWSCredentials(accessKeyId: Self.localAccessKey, secretAccessKey: Self.localAccessKey, sessionToken: nil)
        }
        if !forceRefresh, let current = lock.withLock({ cached }), !current.isExpired() {
            return current
        }
        let fresh = try await AWSCredentialResolver.resolve(source: method.credentialSource, fields: fields)
        lock.withLock { cached = fresh }
        return fresh
    }
}

/// Sends DynamoDB requests: signs them, classifies failures, and retries what may be retried.
final class DynamoDBClient: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DynamoDBClient")

    let endpoint: DynamoDBEndpoint
    private let transport: DynamoDBTransport
    private let credentials: DynamoDBCredentialsProvider
    private let retryPolicy: DynamoDBRetryPolicy
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let lock = NSLock()
    private var clockOffset: TimeInterval = 0
    private let timeout = HttpQueryTimeoutBox()

    init(
        endpoint: DynamoDBEndpoint,
        credentials: DynamoDBCredentialsProvider,
        transport: DynamoDBTransport = DynamoDBURLSessionTransport(),
        retryPolicy: DynamoDBRetryPolicy = DynamoDBRetryPolicy(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.now = now
        self.sleep = sleep
    }

    func setQueryTimeout(_ seconds: Int) {
        timeout.set(serverTimeoutSeconds: seconds)
    }

    var queryTimeoutSeconds: Int {
        timeout.current.serverTimeoutSeconds
    }

    func invalidate() {
        transport.invalidate()
    }

    func send(_ operation: DynamoDBOperation, _ body: [String: DynamoDBJSON]) async throws -> DynamoDBJSON {
        try await send(operation, .object(body))
    }

    /// The wait before resending the part of a batch DynamoDB left unprocessed, which it does when
    /// the table is throttled, so it backs off like a throttled request.
    func backOff(afterAttempt attempt: Int) async throws {
        do {
            try await sleep(retryPolicy.delay(base: DynamoDBRetryPolicy.throttlingBase, attempt: attempt))
        } catch {
            throw DynamoDBError.cancelled
        }
    }

    func send(_ operation: DynamoDBOperation, _ body: DynamoDBJSON) async throws -> DynamoDBJSON {
        var attempt = 0
        var refreshedCredentials = false
        var correctedClock = false
        var refreshBeforeNextAttempt = false
        while true {
            attempt += 1
            try checkCancellation()
            do {
                let forceRefresh = refreshBeforeNextAttempt
                refreshBeforeNextAttempt = false
                return try await sendOnce(operation, body: body, forceRefresh: forceRefresh)
            } catch let error as DynamoDBError {
                let decision = retryPolicy.decision(
                    for: error,
                    attempt: attempt,
                    operation: operation,
                    body: body,
                    alreadyRefreshedCredentials: refreshedCredentials,
                    alreadyCorrectedClock: correctedClock
                )
                switch decision {
                case .retry(let delay):
                    Self.logger.info("\(operation.rawValue, privacy: .public) retry \(attempt) after \(delay)s")
                    do {
                        try await sleep(delay)
                    } catch {
                        throw DynamoDBError.cancelled
                    }
                case .refreshCredentialsAndRetry:
                    refreshedCredentials = true
                    refreshBeforeNextAttempt = true
                case .correctClockAndRetry:
                    correctedClock = true
                case .fail:
                    throw error
                }
            }
        }
    }

    private func sendOnce(_ operation: DynamoDBOperation, body: DynamoDBJSON, forceRefresh: Bool) async throws -> DynamoDBJSON {
        let signingCredentials = try await credentials.credentials(forceRefresh: forceRefresh)
        let payload = body.serializedData
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = timeout.requestTimeoutInterval
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue(operation.target, forHTTPHeaderField: "X-Amz-Target")
        let signingDate = now().addingTimeInterval(lock.withLock { clockOffset })
        DynamoDBSigner.sign(
            &request, body: payload, credentials: signingCredentials,
            region: endpoint.signingRegion, date: signingDate
        )

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw DynamoDBError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw DynamoDBError.cancelled
        } catch let error as DynamoDBError {
            throw error
        } catch {
            throw DynamoDBError.transport(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            guard !data.isEmpty else { return .object([:]) }
            do {
                return try DynamoDBJSON.parse(data)
            } catch {
                Self.logger.error("\(operation.rawValue, privacy: .public) response did not parse, \(data.count) bytes")
                throw DynamoDBError.invalidResponse(error.localizedDescription)
            }
        case 300..<400:
            throw DynamoDBError.configuration(String(
                localized: "The endpoint answered with a redirect, which DynamoDB never sends. Check the Custom Endpoint."
            ))
        default:
            let serviceError = DynamoDBServiceError.parse(body: data, httpStatus: response.statusCode)
            if serviceError.category == .clockSkew {
                adoptServerClock(from: response)
            }
            Self.logger.info(
                "\(operation.rawValue, privacy: .public) failed \(response.statusCode) \(serviceError.code, privacy: .public)"
            )
            throw DynamoDBError.service(serviceError)
        }
    }

    private func adoptServerClock(from response: HTTPURLResponse) {
        guard let header = response.value(forHTTPHeaderField: "Date"),
              let serverDate = Self.httpDateFormatter.date(from: header)
        else { return }
        let offset = serverDate.timeIntervalSince(now())
        lock.withLock { clockOffset = offset }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw DynamoDBError.cancelled }
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
