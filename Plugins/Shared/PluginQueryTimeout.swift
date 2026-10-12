nonisolated enum PluginQueryTimeout {
    static let maximumSeconds = Int(Int32.max) / 1_000

    static func boundedSeconds(_ seconds: Int) -> Int {
        min(max(seconds, 0), maximumSeconds)
    }

    static func milliseconds(_ seconds: Int) -> Int {
        boundedSeconds(seconds) * 1_000
    }

    static func int32Milliseconds(_ seconds: Int) -> Int32 {
        Int32(milliseconds(seconds))
    }

    static func microseconds(_ seconds: Int) -> Int64 {
        Int64(boundedSeconds(seconds)) * 1_000_000
    }
}
