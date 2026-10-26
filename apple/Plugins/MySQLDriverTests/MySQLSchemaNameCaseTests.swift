import Foundation
import TableProPluginKit
import Testing

struct MySQLSchemaNameCaseTests {
    private func makeDriver() -> MySQLPluginDriver {
        MySQLPluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: "", additionalFields: [:]
        ))
    }

    @Test("A server that does not answer keeps the plain comparison and records nothing")
    func unansweredReadIsNotRecorded() async {
        let driver = makeDriver()

        #expect(await driver.schemaNamesAreCaseSensitive() == false)
        #expect(driver.cachedSchemaNamesAreCaseSensitive == nil)
    }

    @Test("A recorded answer is used without asking the server again")
    func recordedAnswerIsReused() async {
        let driver = makeDriver()
        driver.cachedSchemaNamesAreCaseSensitive = true

        #expect(await driver.schemaNamesAreCaseSensitive())
    }

    @Test("Disconnecting forgets the answer, since the next server may differ")
    func disconnectForgetsTheAnswer() {
        let driver = makeDriver()
        driver.cachedSchemaNamesAreCaseSensitive = true

        driver.disconnect()

        #expect(driver.cachedSchemaNamesAreCaseSensitive == nil)
    }
}
