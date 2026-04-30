import Foundation

protocol MCPRouteHandler: Sendable {
    var methods: [HTTPRequest.Method] { get }
    var path: String { get }
    func handle(_ request: HTTPRequest) async -> MCPRouter.RouteResult
}
