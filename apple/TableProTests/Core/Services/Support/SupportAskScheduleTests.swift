//
//  SupportAskScheduleTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SupportAskScheduleTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private let askedAt = Date(timeIntervalSince1970: 1_793_000_000)

    private func day(_ offset: Int) -> Date {
        askedAt.addingTimeInterval(TimeInterval(offset) * 86_400)
    }

    @Test("Nothing is asked before the 30th day of use")
    func waitsForTheThirtiethDay() {
        let before = SupportAskSchedule(usageDays: 29, hasLicense: false, lastAskedAt: nil, lastAnswer: nil)
        let on = SupportAskSchedule(usageDays: 30, hasLicense: false, lastAskedAt: nil, lastAnswer: nil)

        #expect(!before.isDue(at: askedAt, calendar: calendar))
        #expect(on.isDue(at: askedAt, calendar: calendar))
    }

    @Test("A license closes the ask whatever the count")
    func licenseClosesIt() {
        let schedule = SupportAskSchedule(usageDays: 400, hasLicense: true, lastAskedAt: nil, lastAnswer: nil)

        #expect(!schedule.isDue(at: askedAt, calendar: calendar))
    }

    @Test(
        "After any answer but personal use, the next ask waits 90 days",
        arguments: [nil, SupportAskAnswer.buy, .notNow] as [SupportAskAnswer?]
    )
    func ninetyDaysAfterAnAsk(answer: SupportAskAnswer?) {
        let schedule = SupportAskSchedule(usageDays: 45, hasLicense: false, lastAskedAt: askedAt, lastAnswer: answer)

        #expect(!schedule.isDue(at: day(89), calendar: calendar))
        #expect(schedule.isDue(at: day(90), calendar: calendar))
    }

    @Test("Personal use quiets the ask for a year")
    func personalUseWaitsAYear() {
        let schedule = SupportAskSchedule(usageDays: 45, hasLicense: false, lastAskedAt: askedAt, lastAnswer: .personal)

        #expect(!schedule.isDue(at: day(90), calendar: calendar))
        #expect(!schedule.isDue(at: day(364), calendar: calendar))
        #expect(schedule.isDue(at: day(365), calendar: calendar))
    }

    @Test("The ask waits out the first five minutes after launch")
    func launchQuietPeriod() {
        let launchedAt = askedAt

        #expect(!SupportAskSchedule.isQuietMoment(
            launchedAt: launchedAt, now: launchedAt.addingTimeInterval(299), isQueryRunning: false
        ))
        #expect(SupportAskSchedule.isQuietMoment(
            launchedAt: launchedAt, now: launchedAt.addingTimeInterval(300), isQueryRunning: false
        ))
    }

    @Test("A running query holds the ask")
    func runningQueryHoldsIt() {
        #expect(!SupportAskSchedule.isQuietMoment(
            launchedAt: askedAt, now: askedAt.addingTimeInterval(3_600), isQueryRunning: true
        ))
    }
}
