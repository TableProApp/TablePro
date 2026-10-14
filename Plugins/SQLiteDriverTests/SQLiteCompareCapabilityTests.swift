import TableProPluginKit
import Testing

struct SQLiteCompareCapabilityTests {
    @Test("The driver declares both compare capabilities Compare & Sync is gated on")
    func declaresCompareCapabilities() {
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: ""
        ))

        #expect(
            driver.capabilities.contains(.schemaCompare),
            "Without .schemaCompare, Compare & Sync refuses every structure comparison"
        )
        #expect(
            driver.capabilities.contains(.dataCompare),
            "Without .dataCompare, Compare & Sync refuses every data comparison"
        )
    }
}
