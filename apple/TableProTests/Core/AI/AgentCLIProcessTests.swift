import Foundation
@testable import TablePro
import Testing

struct AgentCLIProcessTests {
    private let shellLaunch = AgentCLILaunch(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exit 0"],
        environment: [:]
    )

    @Test("A launch the launcher refuses fails as a launch failure instead of running")
    func refusedLaunchFailsTheRun() async {
        await #expect(throws: AgentCLIError.self) {
            _ = try await AgentCLIProcess(label: "claude").run(shellLaunch)
        }
    }

    @Test("A launch the launcher refuses ends the line stream with a launch failure")
    func refusedLaunchEndsTheStream() async {
        await #expect(throws: AgentCLIError.self) {
            for try await _ in AgentCLIProcess(label: "claude").streamLines(shellLaunch) {}
        }
    }
}
