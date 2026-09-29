import Foundation
import TableProPluginKit
import Testing

private final class HranaEchoingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil),
              let body = Self.echoedArgumentsResponse(to: Self.bodyData(of: request))
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func echoedArgumentsResponse(to requestBody: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              let requests = root["requests"] as? [[String: Any]],
              let statement = requests.first?["stmt"] as? [String: Any]
        else { return nil }
        let args = statement["args"] as? [Any] ?? []
        let columns = args.indices.map { ["name": "a\($0)"] }
        let result: [String: Any] = ["cols": columns, "rows": [args], "affected_row_count": 0]
        let item: [String: Any] = ["type": "ok", "response": ["type": "execute", "result": result]]
        return try? JSONSerialization.data(withJSONObject: ["results": [item]])
    }

    private static func bodyData(of request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private extension HranaValue {
    var textValue: String? {
        guard case .text(let text) = self else { return nil }
        return text
    }

    var blobValue: Data? {
        guard case .blob(let data) = self else { return nil }
        return data
    }
}

struct HranaHttpClientArgumentEncodingTests {
    private func encodedStatements(_ statements: [HranaStatement]) throws -> [[String: Any]] {
        let body = try HranaHttpClient.pipelineRequestBody(statements: statements)
        let object = try JSONSerialization.jsonObject(with: body)
        let root = try #require(object as? [String: Any])
        let requests = try #require(root["requests"] as? [[String: Any]])
        #expect(requests.map { $0["type"] as? String } == Array(repeating: "execute", count: requests.count))
        return try requests.map { request -> [String: Any] in
            try #require(request["stmt"] as? [String: Any])
        }
    }

    private func encodedArguments(_ args: [PluginCellValue]) throws -> [[String: String]] {
        let statements = try encodedStatements([HranaStatement(sql: "INSERT INTO t VALUES (?)", parameters: args)])
        let statement = try #require(statements.first)
        return try #require(statement["args"] as? [[String: String]])
    }

    private func echoingClient() throws -> HranaHttpClient {
        let url = try #require(URL(string: "https://db.turso.test"))
        let client = HranaHttpClient(baseUrl: url, authToken: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HranaEchoingProtocol.self]
        client.createSession(configuration: configuration)
        return client
    }

    @Test(arguments: ["007", "1.50", "+5", "0x10", "1e3", "12345678901234567890", "-0"])
    func numericLookingTextIsSentAsText(_ text: String) throws {
        let args = try encodedArguments([.text(text)])

        #expect(args == [["type": "text", "value": text]])
    }

    @Test(arguments: ["inf", "nan", "Infinity", "NaN", "-inf", "1e999"])
    func nonFiniteLookingTextIsSentAsText(_ text: String) throws {
        let args = try encodedArguments([.text(text)])

        #expect(args == [["type": "text", "value": text]])
    }

    @Test
    func bytesAreSentAsBase64Blob() throws {
        let args = try encodedArguments([.bytes(Data([0xAB])), .bytes(Data())])

        #expect(args == [["type": "blob", "base64": "qw=="], ["type": "blob", "base64": ""]])
    }

    @Test
    func nullIsSentAsNull() throws {
        let args = try encodedArguments([.null, .text("x")])

        #expect(args == [["type": "null"], ["type": "text", "value": "x"]])
    }

    @Test
    func statementWithoutArgumentsCarriesNoArgs() throws {
        let statements = try encodedStatements([
            HranaStatement(sql: "SELECT 1"),
            HranaStatement(sql: "SELECT ?", parameters: [.text("1")])
        ])

        #expect(statements.map { $0["sql"] as? String } == ["SELECT 1", "SELECT ?"])
        #expect(statements.map { $0.keys.contains("args") } == [false, true])
    }

    @Test(arguments: ["inf", "nan", "007", "1.50"])
    func executeSendsTextArgumentsAsText(_ text: String) async throws {
        let client = try echoingClient()
        defer { client.invalidateSession() }

        let result = try await client.execute(sql: "SELECT ?", args: [.text(text)])

        #expect(result.rows.first?.first?.textValue == text)
    }

    @Test
    func executeSendsBytesAsBlob() async throws {
        let client = try echoingClient()
        defer { client.invalidateSession() }

        let result = try await client.execute(sql: "SELECT ?", args: [.bytes(Data([0xAB]))])

        #expect(result.rows.first?.first?.blobValue == Data([0xAB]))
    }
}
