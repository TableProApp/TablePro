import Foundation
import Testing

struct MSSQLEntraConnectSessionTests {
    @Test("Entra refresh requests allow the longest supported connect window")
    func connectSessionTimeouts() {
        let configuration = MSSQLEntraConnectSession.configuration()

        #expect(configuration.timeoutIntervalForRequest == 600)
        #expect(configuration.timeoutIntervalForResource == 3_600)
        #expect(MSSQLEntraConnectSession.shared.configuration.timeoutIntervalForRequest == 600)
        #expect(MSSQLEntraConnectSession.shared.configuration.timeoutIntervalForResource == 3_600)
    }
}
