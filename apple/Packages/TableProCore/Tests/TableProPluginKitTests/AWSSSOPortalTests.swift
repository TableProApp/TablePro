import Foundation
import TableProPluginKit
import Testing

struct AWSSSOPortalTests {
    @Test("listAccounts follows nextToken to the last page")
    func listAccountsFollowsNextToken() async throws {
        let script = AWSSSOScriptedProtocol.Script { request, _ in
            switch queryValues(of: request)["next_token"] {
            case nil:
                return .json(#"""
                {"accountList":[{"accountId":"111111111111","accountName":"Production","emailAddress":"prod@example.com"}],
                 "nextToken":"page+2/=="}
                """#)
            case "page+2/=="?:
                return .json(#"{"accountList":[{"accountId":"222222222222","accountName":"Staging"}],"nextToken":null}"#)
            default:
                return .json(#"{"message":"unknown token"}"#, status: 400)
            }
        }

        let accounts = try await AWSSSOPortal.listAccounts(
            region: "eu-west-1",
            accessToken: "BEARER",
            session: AWSSSOScriptedProtocol.session(for: script)
        )

        #expect(accounts == [
            AWSSSOAccount(accountId: "111111111111", accountName: "Production", emailAddress: "prod@example.com"),
            AWSSSOAccount(accountId: "222222222222", accountName: "Staging")
        ])
        let requests = script.exchanges.map(\.request)
        try #require(requests.count == 2)
        for request in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.url?.host == "portal.sso.eu-west-1.amazonaws.com")
            #expect(request.url?.path == "/assignment/accounts")
            #expect(request.value(forHTTPHeaderField: "x-amz-sso_bearer_token") == "BEARER")
            #expect(queryValues(of: request)["max_result"] == "100")
        }
        #expect(queryValues(of: requests[0])["next_token"] == nil)
        let secondQuery = try #require(requests.last?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        })
        #expect(secondQuery.contains("next_token=page%2B2%2F%3D%3D"))
    }

    @Test("listAccountRoles follows nextToken and keeps the account on every page")
    func listAccountRolesFollowsNextToken() async throws {
        let script = AWSSSOScriptedProtocol.Script { request, _ in
            switch queryValues(of: request)["next_token"] {
            case nil:
                return .json(#"{"roleList":[{"accountId":"111111111111","roleName":"ReadOnly"}],"nextToken":"roles-2"}"#)
            case "roles-2"?:
                return .json(#"{"roleList":[{"roleName":"Admin"}]}"#)
            default:
                return .json(#"{"message":"unknown token"}"#, status: 400)
            }
        }

        let roles = try await AWSSSOPortal.listAccountRoles(
            region: "us-east-1",
            accessToken: "BEARER",
            accountId: "111111111111",
            session: AWSSSOScriptedProtocol.session(for: script)
        )

        #expect(roles == [
            AWSSSOAccountRole(accountId: "111111111111", roleName: "ReadOnly"),
            AWSSSOAccountRole(accountId: "111111111111", roleName: "Admin")
        ])
        let requests = script.exchanges.map(\.request)
        try #require(requests.count == 2)
        for request in requests {
            #expect(request.url?.host == "portal.sso.us-east-1.amazonaws.com")
            #expect(request.url?.path == "/assignment/roles")
            #expect(request.value(forHTTPHeaderField: "x-amz-sso_bearer_token") == "BEARER")
            #expect(queryValues(of: request)["account_id"] == "111111111111")
            #expect(queryValues(of: request)["max_result"] == "100")
        }
        #expect(queryValues(of: requests[1])["next_token"] == "roles-2")
    }

    @Test("A rejected token reports the portal's own message")
    func rejectedTokenReportsPortalMessage() async {
        let errorType = "UnauthorizedException:http://internal.amazon.com/coral/com.amazonaws.switchboard.portal/"
        let withMessage = AWSSSOScriptedProtocol.Script { _, _ in
            .json(#"{"message":"Session token not found or invalid"}"#, status: 401, headers: ["x-amzn-ErrorType": errorType])
        }
        await #expect(throws: AWSSSOLoginError.serverError("Session token not found or invalid")) {
            _ = try await AWSSSOPortal.listAccounts(
                region: "us-east-1",
                accessToken: "EXPIRED",
                session: AWSSSOScriptedProtocol.session(for: withMessage)
            )
        }

        let typeOnly = AWSSSOScriptedProtocol.Script { _, _ in
            .init(status: 401, headers: ["x-amzn-ErrorType": errorType])
        }
        await #expect(throws: AWSSSOLoginError.serverError("UnauthorizedException")) {
            _ = try await AWSSSOPortal.listAccountRoles(
                region: "us-east-1",
                accessToken: "EXPIRED",
                accountId: "111111111111",
                session: AWSSSOScriptedProtocol.session(for: typeOnly)
            )
        }
    }

    @Test("A nextToken the portal already returned stops the listing")
    func repeatedNextTokenStops() async {
        let script = AWSSSOScriptedProtocol.Script { _, _ in
            .json(#"{"accountList":[{"accountId":"111111111111"}],"nextToken":"same"}"#)
        }
        await #expect(throws: AWSSSOLoginError.unexpectedResponse) {
            _ = try await AWSSSOPortal.listAccounts(
                region: "us-east-1",
                accessToken: "BEARER",
                session: AWSSSOScriptedProtocol.session(for: script)
            )
        }
        #expect(script.exchanges.count == 2)
    }
}

private func queryValues(of request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

// Each session carries its own route header, so cases running in parallel never read each other's
// replies or requests through the shared protocol class.
final class AWSSSOScriptedProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: Data(text.utf8), headers: headers)
        }
    }

    struct Exchange {
        let request: URLRequest
        let body: Data
    }

    final class Script: @unchecked Sendable {
        typealias Respond = @Sendable (_ request: URLRequest, _ callIndex: Int) -> Reply

        private let respond: Respond
        private let lock = NSLock()
        private var recorded: [Exchange] = []

        init(_ respond: @escaping Respond) {
            self.respond = respond
        }

        var exchanges: [Exchange] {
            lock.withLock { recorded }
        }

        func calls(to path: String) -> [Exchange] {
            exchanges.filter { $0.request.url?.path == path }
        }

        fileprivate func reply(to request: URLRequest, body: Data) -> Reply {
            let callIndex = lock.withLock { () -> Int in
                let index = recorded.filter { $0.request.url?.path == request.url?.path }.count
                recorded.append(Exchange(request: request, body: body))
                return index
            }
            return respond(request, callIndex)
        }
    }

    private static let routeHeader = "X-AWSSSO-Scripted-Route"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]

    static func session(for script: Script) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { scripts[id] = script }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AWSSSOScriptedProtocol.self]
        configuration.httpAdditionalHeaders = [routeHeader: id]
        return URLSession(configuration: configuration)
    }

    private static func script(for request: URLRequest) -> Script? {
        guard let id = request.value(forHTTPHeaderField: routeHeader) else { return nil }
        return lock.withLock { scripts[id] }
    }

    // URLSession hands a custom protocol the body as a stream, not as httpBody.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let script = Self.script(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let reply = script.reply(to: request, body: Self.body(of: request))
        var headers = reply.headers
        headers["Content-Type"] = "application/json"
        guard let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
