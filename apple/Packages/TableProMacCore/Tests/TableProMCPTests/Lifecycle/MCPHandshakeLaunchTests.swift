import AppKit
@testable import TableProMCP
import Testing

struct MCPHandshakeLaunchTests {
    @Test("A background launch keeps the helper environment and overrides the background flag")
    func launchKeepsInheritedEnvironment() {
        let environment = [
            "TABLEPRO_UI_TEST_SANDBOX": "/tmp/tablepro-mcp-test",
            "PATH": "/usr/bin:/bin",
            BackgroundLaunchFlag.variable: "inherited"
        ]

        let configuration = MCPHandshakeAcquirer.launchConfiguration(environment: environment)

        var expected = environment
        expected[BackgroundLaunchFlag.variable] = BackgroundLaunchFlag.value
        #expect(configuration.environment == expected)
        #expect(!configuration.activates)
    }
}
