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

    @Test("Callers that ask while the setting is being read share that one read")
    func concurrentCallersShareOneRead() async {
        let driver = makeDriver()
        let reads = ReadCounter()
        let read: @Sendable () async -> Bool? = {
            await reads.increment()
            return true
        }

        let first = driver.schemaNameCase(startingRead: read)
        let second = driver.schemaNameCase(startingRead: read)
        guard case .reading(let firstRead) = first, case .reading(let secondRead) = second else {
            Issue.record("expected both callers to wait on a read")
            return
        }
        let answer = await driver.schemaNamesAreCaseSensitive(reading: read)

        #expect(firstRead == secondRead)
        #expect(answer)
        #expect(await reads.count == 1)
        #expect(driver.cachedSchemaNamesAreCaseSensitive == true)
    }

    @Test("A read that fails stores nothing, so the next caller reads again")
    func failedReadIsAskedAgain() async {
        let driver = makeDriver()
        let reads = ReadCounter()

        let first = await driver.schemaNamesAreCaseSensitive { await reads.increment(); return nil }
        let second = await driver.schemaNamesAreCaseSensitive { await reads.increment(); return true }

        #expect(first == false)
        #expect(second)
        #expect(await reads.count == 2)
    }

    @Test("A disconnect while the setting is being read leaves nothing recorded")
    func disconnectDuringReadStoresNothing() async {
        let driver = makeDriver()
        let gate = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()

        async let answer = driver.schemaNamesAreCaseSensitive {
            started.continuation.yield()
            for await _ in gate.stream { break }
            return true
        }
        for await _ in started.stream { break }
        driver.disconnect()
        gate.continuation.yield()

        #expect(await answer)
        #expect(driver.cachedSchemaNamesAreCaseSensitive == nil)
    }
}

private actor ReadCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
