import Foundation

// Sized by RAM and never by pressure: dispatch/source.h says not to walk and discard existing caches when pressure rises.
public enum GridDisplayCacheBudget {
    public static func unmountedGrids(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let gigabyte: UInt64 = 1_073_741_824
        switch physicalMemory {
        case (32 * gigabyte)...:
            return 8
        case (16 * gigabyte)...:
            return 5
        case (8 * gigabyte)...:
            return 3
        default:
            return 2
        }
    }
}
