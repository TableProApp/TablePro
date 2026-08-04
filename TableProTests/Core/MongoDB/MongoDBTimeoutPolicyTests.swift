//
//  MongoDBTimeoutPolicyTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("MongoDB Timeout Policy")
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

    @Test("Only MaxTimeMSExpired counts as a timeout")
    func timeoutCodeDetection() {
        #expect(MongoDBTimeoutPolicy.isTimeoutCode(50))
        #expect(!MongoDBTimeoutPolicy.isTimeoutCode(0))
        #expect(!MongoDBTimeoutPolicy.isTimeoutCode(292))
    }
}
