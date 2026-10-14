import Foundation

public struct WaitTimeout: Error, CustomStringConvertible {
    public let description: String
}

/// For an effect no event reports, such as a file appearing or a count another thread bumps.
/// It sleeps between checks, which frees the caller's actor; `Task.yield` gives no ordering.
nonisolated(nonsending) public func waitUntil(
    timeout: Duration = .seconds(10),
    fileID: String = #fileID,
    line: Int = #line,
    _ condition: nonisolated(nonsending) () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while try await !condition() {
        guard clock.now < deadline else {
            throw WaitTimeout(description: "\(fileID):\(line): condition still false after \(timeout)")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
