import Testing

@testable import TableProUtilities

struct GridDisplayCacheBudgetTests {
    private static let gigabyte: UInt64 = 1_073_741_824

    @Test(
        "More memory keeps more unmounted grids formatted",
        arguments: [
            (UInt64(4) * gigabyte, 2),
            (UInt64(8) * gigabyte, 3),
            (UInt64(16) * gigabyte, 5),
            (UInt64(24) * gigabyte, 5),
            (UInt64(32) * gigabyte, 8),
            (UInt64(128) * gigabyte, 8),
        ]
    )
    func tiers(physicalMemory: UInt64, expected: Int) {
        #expect(GridDisplayCacheBudget.unmountedGrids(physicalMemory: physicalMemory) == expected)
    }

    @Test("Just under a tier stays on the lower one")
    func tierBoundary() {
        #expect(GridDisplayCacheBudget.unmountedGrids(physicalMemory: 16 * Self.gigabyte - 1) == 3)
    }
}
