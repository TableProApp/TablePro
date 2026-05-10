import ActivityKit
import Foundation

struct QueryActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var elapsed: TimeInterval
        var rowsStreamed: Int
    }

    let connectionName: String
    let queryPreview: String
}
