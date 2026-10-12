import Foundation
import Testing

struct CassandraConnectTimeoutTests {
    @Test("The remaining millisecond budget is the DataStax native timeout")
    func nativeMilliseconds() {
        let timeout = CassandraConnectTimeout(additionalFields: [
            "connectTimeoutMilliseconds": "3210",
            "connectTimeoutSeconds": "9"
        ])

        #expect(timeout.milliseconds == 3_210)
        #expect(timeout.nativeConfiguration == CassandraConnectTimeout.NativeConfiguration(
            connectMilliseconds: 3_210,
            resolveMilliseconds: 3_210,
            waitMicroseconds: 3_210_000
        ))
    }

    @Test("One deadline shrinks before the timed connection future")
    func deadlineShrinks() {
        let deadline = CassandraConnectDeadline(timeout: CassandraConnectTimeout(milliseconds: 3_250), now: 10)

        #expect(deadline.remainingMilliseconds(now: 11) == 2_250)
        #expect(deadline.remainingMilliseconds(now: 13.25) == nil)
    }

    @Test("AWS authentication and the native connection share one deadline")
    func awsAuthenticationSharesDeadline() throws {
        let deadline = CassandraConnectDeadline(timeout: CassandraConnectTimeout(milliseconds: 3_250), now: 10)

        let awsBudget = try #require(deadline.awsSessionBudget(now: 11))
        #expect(awsBudget.remainingSeconds == 2.25)
        #expect(awsBudget.expiresAtUptime == 13.25)
        #expect(deadline.remainingMilliseconds(now: 12.25) == 1_000)
        #expect(deadline.awsSessionBudget(now: 13.25) == nil)
    }

    @Test("Server version probe uses the remaining connect budget and preserves its failure")
    func serverVersionProbeUsesDeadline() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let connection = try String(
            contentsOf: root.appendingPathComponent("Plugins/CassandraDriverPlugin/CassandraConnection.swift"),
            encoding: .utf8
        )
        let plugin = try String(
            contentsOf: root.appendingPathComponent("Plugins/CassandraDriverPlugin/CassandraPlugin.swift"),
            encoding: .utf8
        )

        #expect(connection.contains("func serverVersion(requestTimeoutMilliseconds: UInt32)"))
        #expect(connection.contains("cass_statement_set_request_timeout(statement, UInt64(requestTimeoutMilliseconds))"))
        #expect(plugin.contains("requestTimeoutMilliseconds: versionProbeMilliseconds"))
        #expect(!plugin.contains("try? await connectionActor.serverVersion"))
        #expect(plugin.contains("throw CassandraPluginError.connectionFailed(error.localizedDescription)"))
    }

    @Test("The compatibility seconds value is checked and clamped")
    func secondsFallbackClamps() {
        #expect(CassandraConnectTimeout(additionalFields: ["connectTimeoutSeconds": "6"]).milliseconds == 6_000)
        #expect(CassandraConnectTimeout(additionalFields: ["connectTimeoutSeconds": "0"]).milliseconds == 1)
        #expect(
            CassandraConnectTimeout(additionalFields: ["connectTimeoutMilliseconds": "999999999"]).milliseconds
                == UInt32(CassandraConnectTimeout.maximumMilliseconds)
        )
    }
}
