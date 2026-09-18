import Foundation
@testable import TableProSpannerCore

struct RecordedSpannerCall: Sendable {
    let verb: String
    let path: String
    let body: [String: String]
    let sql: String?
    let queryMode: String?
    let seqno: String?
    let transaction: String
    let paramTypeCodes: [String: String]
}

final class SpannerFakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [RecordedSpannerCall] = []
    private var sessionCounter = 0
    private var transactionCounter = 0
    private var pendingFailures: [String: [StubSpannerResponse]] = [:]
    private var operationPolls = 0

    var undeclaredParameters: [(name: String, code: String)] = []
    var queryFields: [(name: String, code: String)] = [("v", "INT64")]
    var queryRows: [[String]] = [["1"]]
    var operationPollsUntilDone = 1
    var operationNeverFinishes = false

    var recorded: [RecordedSpannerCall] {
        lock.withLock { calls }
    }

    func calls(verb: String) -> [RecordedSpannerCall] {
        recorded.filter { $0.verb == verb }
    }

    func failNext(_ verb: String, with response: StubSpannerResponse) {
        lock.withLock { pendingFailures[verb, default: []].append(response) }
    }

    func makeTransport() -> StubSpannerTransport {
        StubSpannerTransport(responder: { [self] request in self.respond(to: request) })
    }

    static let abortedBody = #"{"error":{"code":409,"status":"ABORTED","message":"Transaction was aborted."}}"#
    static let sessionNotFoundBody = """
    {"code":5,"message":"Session not found: projects/proj/instances/inst/databases/gdb/sessions/9",\
    "details":[{"@type":"type.googleapis.com/google.rpc.ResourceInfo",\
    "resourceType":"type.googleapis.com/google.spanner.v1.Session"}]}
    """

    private func respond(to request: URLRequest) -> StubSpannerResponse {
        let call = Self.record(request)
        lock.withLock { calls.append(call) }
        if let failure = lock.withLock({ () -> StubSpannerResponse? in
            guard var queue = pendingFailures[call.verb], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            pendingFailures[call.verb] = queue
            return next
        }) {
            return failure
        }
        switch call.verb {
        case "createSession":
            return .json(#"{"name":"projects/proj/instances/inst/databases/gdb/sessions/\#(nextSession())"}"#)
        case "executeSql":
            return .json(executeSqlBody(call))
        case "executeStreamingSql":
            return .stream([streamBody()])
        case "beginTransaction":
            return .json(#"{"id":"\#(nextTransaction())"}"#)
        case "updateDdl":
            return .json(#"{"name":"projects/proj/instances/inst/databases/gdb/operations/op1","done":false}"#)
        case "operation":
            return .json(operationBody())
        default:
            return .json("{}")
        }
    }

    private func nextSession() -> String {
        lock.withLock {
            sessionCounter += 1
            return "s\(sessionCounter)"
        }
    }

    private func nextTransaction() -> String {
        lock.withLock {
            transactionCounter += 1
            return "tx\(transactionCounter)"
        }
    }

    private func executeSqlBody(_ call: RecordedSpannerCall) -> String {
        let transaction = call.transaction == "begin" ? #","transaction":{"id":"\#(nextTransaction())"}"# : ""
        let undeclared = undeclaredParameters.map { #"{"name":"\#($0.name)","type":{"code":"\#($0.code)"}}"# }
            .joined(separator: ",")
        if call.queryMode == "PLAN" {
            return """
            {"metadata":{"rowType":{"fields":[]}\(transaction),"undeclaredParameters":{"fields":[\(undeclared)]}},\
            "stats":{"queryPlan":{"planNodes":[{"index":0,"kind":"RELATIONAL","displayName":"Distributed Union"}]}}}
            """
        }
        return #"{"metadata":{"rowType":{"fields":[]}\#(transaction)},"stats":{"rowCountExact":"3"}}"#
    }

    private func streamBody() -> String {
        let fields = queryFields.map { #"{"name":"\#($0.name)","type":{"code":"\#($0.code)"}}"# }.joined(separator: ",")
        let values = queryRows.flatMap { $0 }.map { #""\#($0)""# }.joined(separator: ",")
        return #"{"result":{"metadata":{"rowType":{"fields":[\#(fields)]}},"values":[\#(values)]}}"#
    }

    private func operationBody() -> String {
        let done = lock.withLock { () -> Bool in
            operationPolls += 1
            return !operationNeverFinishes && operationPolls >= operationPollsUntilDone
        }
        return #"{"name":"projects/proj/instances/inst/databases/gdb/operations/op1","done":\#(done)}"#
    }

    private static func record(_ request: URLRequest) -> RecordedSpannerCall {
        let path = request.url?.path ?? ""
        let body = request.jsonBody ?? [:]
        let transaction = body["transaction"] as? [String: Any] ?? [:]
        let selector: String
        if transaction["begin"] != nil {
            selector = "begin"
        } else if let identifier = transaction["id"] as? String {
            selector = identifier
        } else if transaction["singleUse"] != nil {
            selector = "singleUse"
        } else {
            selector = ""
        }
        let paramTypes = (body["paramTypes"] as? [String: [String: Any]] ?? [:]).compactMapValues { $0["code"] as? String }
        return RecordedSpannerCall(
            verb: verb(method: request.httpMethod ?? "GET", path: path),
            path: path,
            body: body.compactMapValues { $0 as? String },
            sql: body["sql"] as? String,
            queryMode: body["queryMode"] as? String,
            seqno: body["seqno"] as? String,
            transaction: selector,
            paramTypeCodes: paramTypes
        )
    }

    private static func verb(method: String, path: String) -> String {
        if let colon = path.lastIndex(of: ":") {
            return String(path[path.index(after: colon)...])
        }
        switch method {
        case "DELETE":
            return "deleteSession"
        case "PATCH":
            return "updateDdl"
        case "POST" where path.hasSuffix("/sessions"):
            return "createSession"
        case "GET" where path.contains("/operations/"):
            return "operation"
        case "GET" where path.hasSuffix("/ddl"):
            return "getDdl"
        default:
            return method
        }
    }
}

extension SpannerTestFixtures {
    static func executor(
        server: SpannerFakeServer,
        dialect: SpannerDialect = .googleSQL,
        ddlDeadline: @escaping @Sendable () -> Duration? = { nil }
    ) throws -> (SpannerExecutor, StubSpannerTransport) {
        let transport = server.makeTransport()
        let client = try emulatorClient(transport: transport)
        let executor = SpannerExecutor(
            client: client,
            dialect: dialect,
            ddlDeadline: ddlDeadline,
            abortedRetryDelays: [.zero, .zero, .zero, .zero],
            schemaChangePollInterval: .milliseconds(1)
        )
        return (executor, transport)
    }
}
