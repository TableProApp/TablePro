//
//  ParquetStagingMemoryTests.swift
//  FormatPluginTests
//

import Foundation
import Testing

struct ParquetStagingMemoryTests {
    private static let gibibyte: UInt64 = 1 << 30

    @Test(
        "The staging limit is a sixteenth of the machine's memory, from 1 to 4 GiB",
        arguments: [
            (physical: UInt64(4), limitMiB: UInt64(1_024)),
            (physical: 8, limitMiB: 1_024),
            (physical: 16, limitMiB: 1_024),
            (physical: 24, limitMiB: 1_536),
            (physical: 32, limitMiB: 2_048),
            (physical: 64, limitMiB: 4_096),
            (physical: 512, limitMiB: 4_096)
        ]
    )
    func limitFollowsPhysicalMemory(physical: UInt64, limitMiB: UInt64) {
        let limit = ParquetStaging.memoryLimit(physicalMemory: physical * Self.gibibyte)

        #expect(limit == limitMiB << 20)
        #expect(ParquetStaging.memoryLimitSetting(bytes: limit) == "\(limitMiB)MiB")
    }

    @Test("An export that fits under the limit runs once, with the limit")
    func successRunsOnce() async throws {
        var attempts: [UInt64?] = []

        let result = try await ParquetStaging.retryingWithoutMemoryLimit(limit: 42) { limit in
            attempts.append(limit)
            return "written"
        }

        #expect(result == "written")
        #expect(attempts == [42])
    }

    @Test(
        "Running out of memory or losing the staging database runs the table again with no limit",
        arguments: [
            ParquetStaging.StagingError.memoryExhausted("could not allocate block"),
            ParquetStaging.StagingError.stagingLost("failed to offload data block")
        ]
    )
    func memoryFailureRetriesWithoutTheLimit(failure: ParquetStaging.StagingError) async throws {
        var attempts: [UInt64?] = []

        let result = try await ParquetStaging.retryingWithoutMemoryLimit(limit: 42) { limit in
            attempts.append(limit)
            if limit != nil { throw failure }
            return "written"
        }

        #expect(result == "written")
        #expect(attempts == [42, nil])
    }

    @Test("Any other failure is reported at once")
    func otherFailureIsNotRetried() async {
        var attempts: [UInt64?] = []

        await #expect(throws: ParquetStaging.StagingError.self) {
            try await ParquetStaging.retryingWithoutMemoryLimit(limit: 42) { limit -> String in
                attempts.append(limit)
                throw ParquetStaging.StagingError.queryFailed("syntax error")
            }
        }

        #expect(attempts == [42])
    }

    @Test("A failure with no limit in place is the export's failure")
    func secondFailureSurfaces() async {
        var attempts: [UInt64?] = []

        await #expect(throws: ParquetStaging.StagingError.self) {
            try await ParquetStaging.retryingWithoutMemoryLimit(limit: 42) { limit -> String in
                attempts.append(limit)
                throw ParquetStaging.StagingError.memoryExhausted("still too large")
            }
        }

        #expect(attempts == [42, nil])
    }

    @Test("Bytes in a text column keep DuckDB's blob spelling")
    func bytesKeepTheBlobSpelling() {
        let data = Data([0x41, 0x7E, 0x20, 0x5C, 0x27, 0x22, 0x00, 0x7F, 0xFF])

        #expect(ParquetStaging.text(forBytes: data) == #"A~ \x5C\x27\x22\x00\x7F\xFF"#)
    }
}
