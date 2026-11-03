import Foundation
@testable import TablePro
import Testing

struct MCPServerStatusPresentationTests {
    @Test("Every failure offers Try Again and names its cause")
    func failuresOfferRetry() {
        let failures: [MCPServerFailure] = [
            .socketFolderUnusable,
            .listenerUnavailable(detail: "Address already in use"),
            .noBoundPort,
            .credentialUnavailable,
            .listenerStopped(detail: "The listener closed"),
        ]
        for failure in failures {
            let presentation = MCPServerStatusPresentation(state: .failed(failure), configuredPort: 23_508)
            #expect(presentation.status == .failed)
            #expect(presentation.offersRetry)
            #expect(presentation.detail?.isEmpty == false)
        }
    }

    @Test("A listener failure keeps the system's reason in the detail")
    func listenerReasonShows() {
        let presentation = MCPServerStatusPresentation(
            state: .failed(.listenerUnavailable(detail: "Address already in use")),
            configuredPort: 23_508
        )
        #expect(presentation.detail?.contains("Address already in use") == true)
    }

    @Test("A path that happens to contain 48 is not read as a busy port")
    func noFalsePortInUse() {
        let presentation = MCPServerStatusPresentation(
            state: .failed(.listenerUnavailable(detail: "/var/folders/48/T/mcp.sock: permission denied")),
            configuredPort: 23_508
        )
        #expect(presentation.title == String(localized: "Couldn't start"))
        #expect(presentation.detail?.contains("Port 23508") != true)
    }

    @Test("Running on a port the system picked says the configured one was in use")
    func fallbackPortIsNamed() {
        let fallback = MCPServerStatusPresentation(state: .running(port: 51_234), configuredPort: 23_508)
        #expect(fallback.status == .running)
        #expect(fallback.detail == String(format: String(localized: "Port %d was in use."), 23_508))
        #expect(!fallback.offersRetry)

        let configured = MCPServerStatusPresentation(state: .running(port: 23_508), configuredPort: 23_508)
        #expect(configured.detail == nil)
    }

    @Test("Stopped and starting offer nothing")
    func idleStatesOfferNothing() {
        #expect(!MCPServerStatusPresentation(state: .stopped, configuredPort: 23_508).offersRetry)
        #expect(!MCPServerStatusPresentation(state: .starting, configuredPort: 23_508).offersRetry)
    }
}
