import Foundation

public enum SpannerCell: Sendable, Hashable {
    case null
    case text(String)
    case bytes(Data)
}
