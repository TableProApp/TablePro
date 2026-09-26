//
//  MongoDBTimeoutPolicyTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoDBTimeoutPolicyTests {
    @Suite("resolveMaxTimeMS")
    struct ResolveMaxTimeMSTests {
        @Test("Background counts are capped even when no ambient timeout is configured")
        func backgroundWithNoAmbientTimeout() {
            let resolved = MongoDBTimeoutPolicy.resolveMaxTimeMS(ambientMS: 0, background: true)
            #expect(resolved == MongoDBTimeoutPolicy.backgroundMaxTimeMS)
        }

        @Test("Background counts never exceed the cap")
        func backgroundClampsLargeAmbientTimeout() {
            let resolved = MongoDBTimeoutPolicy.resolveMaxTimeMS(ambientMS: 60_000, background: true)
            #expect(resolved == MongoDBTimeoutPolicy.backgroundMaxTimeMS)
        }

        @Test("Background counts honour an ambient timeout shorter than the cap")
        func backgroundHonoursShorterAmbientTimeout() {
            let resolved = MongoDBTimeoutPolicy.resolveMaxTimeMS(ambientMS: 2_000, background: true)
            #expect(resolved == 2_000)
        }

        @Test("User-initiated work uses the ambient timeout")
        func foregroundUsesAmbientTimeout() {
            let resolved = MongoDBTimeoutPolicy.resolveMaxTimeMS(ambientMS: 60_000, background: false)
            #expect(resolved == 60_000)
        }

        @Test("User-initiated work stays unbounded when the user chose no limit")
        func foregroundRespectsNoLimit() {
            let resolved = MongoDBTimeoutPolicy.resolveMaxTimeMS(ambientMS: 0, background: false)
            #expect(resolved == nil)
        }
    }

    @Suite("shouldRetryWithoutHint")
    struct RetryTests {
        @Test("A rejected hint retries without it")
        func retriesOnBadValue() {
            #expect(MongoDBTimeoutPolicy.shouldRetryWithoutHint(errorCode: MongoDBServerErrorCode.badValue))
            #expect(MongoDBTimeoutPolicy.shouldRetryWithoutHint(errorCode: MongoDBServerErrorCode.indexNotFound))
        }

        @Test("A timeout is authoritative and never retried")
        func doesNotRetryOnTimeout() {
            #expect(!MongoDBTimeoutPolicy.shouldRetryWithoutHint(errorCode: MongoDBServerErrorCode.maxTimeMSExpired))
        }

        @Test("Unrelated failures are not retried")
        func doesNotRetryOnOtherErrors() {
            #expect(!MongoDBTimeoutPolicy.shouldRetryWithoutHint(errorCode: MongoDBServerErrorCode.cursorKilled))
            #expect(!MongoDBTimeoutPolicy.shouldRetryWithoutHint(errorCode: 13))
        }
    }

    @Suite("timeoutMessage")
    struct TimeoutMessageTests {
        @Test("Reports the timeout in seconds")
        func reportsSeconds() {
            let message = MongoDBTimeoutPolicy.timeoutMessage(maxTimeMS: 60_000)
            #expect(message.contains("60"))
        }

        @Test("A sub-second timeout still reports at least one second")
        func clampsToOneSecond() {
            let message = MongoDBTimeoutPolicy.timeoutMessage(maxTimeMS: 200)
            #expect(message.contains("1"))
        }

        @Test("Names the missing index as the likely cause")
        func mentionsIndex() {
            let message = MongoDBTimeoutPolicy.timeoutMessage(maxTimeMS: 5_000)
            #expect(message.localizedCaseInsensitiveContains("index"))
        }
    }

    @Test("A write that timed out says it was stopped and names the seconds, rounded to at least one")
    func writeTimeoutMessage() {
        let message = MongoDBTimeoutPolicy.writeTimeoutMessage(maxTimeMS: 30_000)
        #expect(message.contains("30"))
        #expect(message.localizedCaseInsensitiveContains("write"))
        #expect(!message.localizedCaseInsensitiveContains("index"))
        #expect(MongoDBTimeoutPolicy.writeTimeoutMessage(maxTimeMS: 200)
            == MongoDBTimeoutPolicy.writeTimeoutMessage(maxTimeMS: 1_000))
        #expect(MongoDBTimeoutPolicy.writeTimeoutMessage(maxTimeMS: 1_600)
            == MongoDBTimeoutPolicy.writeTimeoutMessage(maxTimeMS: 2_000))
    }

    @Test("The interruption category holds the timeout and a kill, and not a refusal")
    func interruptionCategory() {
        let category = MongoDBServerErrorCode.interruptionCategory
        #expect(category.contains(MongoDBServerErrorCode.maxTimeMSExpired))
        #expect(category.contains(11_601))
        #expect(category.contains(11_602))
        #expect(!category.contains(MongoDBServerErrorCode.badValue))
        #expect(!category.contains(121))
        #expect(!category.contains(11_000))
    }

    @Test("The interruption category holds every Interruption code from MongoDB 4.0 through 9.0")
    func interruptionCategoryCoversEveryRelease() {
        let addedByRelease: [(release: String, codes: [UInt32])] = [
            ("4.0", [24, 50, 237, 262, 11_600, 11_601, 11_602]),
            ("4.2", [279, 282, 46_841]),
            ("4.4", [281, 290]),
            ("5.1", [355]),
            ("8.0", [91_331]),
            ("8.1", [10_045_600]),
            ("8.2", [453]),
            ("8.3", [471, 473, 485]),
            ("9.0", [509])
        ]
        let category = MongoDBServerErrorCode.interruptionCategory
        for (release, codes) in addedByRelease {
            for code in codes {
                #expect(category.contains(code), "MongoDB \(release) code \(code)")
            }
        }
        #expect(category.count == addedByRelease.flatMap { $0.codes }.count)
    }

    @Test("Only MaxTimeMSExpired counts as a timeout")
    func timeoutCodeDetection() {
        #expect(MongoDBTimeoutPolicy.isTimeoutCode(50))
        #expect(!MongoDBTimeoutPolicy.isTimeoutCode(0))
        #expect(!MongoDBTimeoutPolicy.isTimeoutCode(292))
    }
}
