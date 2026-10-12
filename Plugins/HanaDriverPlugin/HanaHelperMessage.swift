import Foundation

enum HanaHelperMessage {
    private struct OpenedSession: Decodable {
        let session: UInt64
    }

    static func session(_ session: UInt64) -> Data {
        Data(#"{"session":\#(session)}"#.utf8)
    }

    static func operation(_ ticket: HanaOperationTicket) -> Data {
        Data(#"{"session":\#(ticket.session),"operation":\#(ticket.operation)}"#.utf8)
    }

    static func statement(_ ticket: HanaOperationTicket, request: Data) -> Data {
        var body = Data(#"{"session":\#(ticket.session),"operation":\#(ticket.operation),"request":"#.utf8)
        body.append(request)
        body.append(contentsOf: "}".utf8)
        return body
    }

    static func openedSession(from reply: Data) throws -> UInt64 {
        guard let opened = try? JSONDecoder().decode(OpenedSession.self, from: reply), opened.session != 0 else {
            throw HanaBridgeFailure(kind: .internalFailure, message: "the helper did not name the session it opened")
        }
        return opened.session
    }
}
