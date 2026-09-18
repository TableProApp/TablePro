//
//  ConnectionHealthCheckTests.swift
//  TableProTests
//
//  The setting behind #2700: how often TablePro talks to a database nobody is using, and the
//  freshness rule that lets it stop talking without the app losing track of whether a connection
//  still works.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Connection health check setting")
struct ConnectionHealthCheckTests {
    @Test("on demand schedules nothing")
    func onDemandHasNoInterval() {
        #expect(ConnectionHealthCheck.onDemand.interval == nil)
    }

    @Test("every other setting schedules its own interval")
    func pollingSettingsCarryTheirInterval() {
        #expect(ConnectionHealthCheck.every30Seconds.interval == .seconds(30))
        #expect(ConnectionHealthCheck.every5Minutes.interval == .seconds(300))
        #expect(ConnectionHealthCheck.every15Minutes.interval == .seconds(900))
    }

    @Test("an answer stays worth believing until the freshness window closes")
    func freshnessIsMeasuredFromTheLastAnswer() {
        let answered = Date()

        #expect(ConnectionHealthCheck.isFresh(answered, now: answered))
        #expect(ConnectionHealthCheck.isFresh(answered, now: answered.addingTimeInterval(299)))
        #expect(!ConnectionHealthCheck.isFresh(answered, now: answered.addingTimeInterval(300)))
        #expect(!ConnectionHealthCheck.isFresh(answered, now: answered.addingTimeInterval(3_600)))
    }

    /// The default has to be today's behaviour, or every user who never opens Settings gets a
    /// change they did not ask for.
    @Test("the default keeps the 30-second check")
    func defaultIsTheThirtySecondCheck() {
        #expect(GeneralSettings.default.connectionHealthCheck == .every30Seconds)
    }

    @Test("settings saved before the option existed decode to the default")
    func absentKeyDecodesToTheDefault() throws {
        let json = Data(#"{"startupBehavior":"reopenLast"}"#.utf8)

        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: json)

        #expect(decoded.connectionHealthCheck == .every30Seconds)
    }

    /// Settings sync between devices, so a newer TablePro can write an interval this build has no
    /// case for. Decoding that as the enum throws, which would take the whole of General down with
    /// it and reset every other setting the user had.
    @Test("an interval from a newer version falls back instead of failing the whole decode")
    func unknownIntervalFallsBack() throws {
        let json = Data(#"{"startupBehavior":"reopenLast","connectionHealthCheck":600,"queryTimeoutSeconds":90}"#.utf8)

        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: json)

        #expect(decoded.connectionHealthCheck == .every30Seconds)
        #expect(decoded.queryTimeoutSeconds == 90, "The rest of General survives an interval it does not know")
    }

    @Test("the choice survives a round trip through storage")
    func choiceRoundTrips() throws {
        var settings = GeneralSettings.default
        settings.connectionHealthCheck = .onDemand

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)

        #expect(decoded.connectionHealthCheck == .onDemand)
    }

    @Test("every option is offered to the picker exactly once")
    func everyOptionIsSelectable() {
        let cases = ConnectionHealthCheck.allCases

        #expect(cases.count == 4)
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(cases.allSatisfy { !$0.title.isEmpty })
    }
}
