import Foundation

@frozen
public enum DefaultSortHint: Sendable, Equatable {
    case useAppDefault
    case suppress
    case forceColumns([String])
}

public protocol PluginDefaultSortProvider: AnyObject, Sendable {
    func defaultSortHint(forTable table: String) -> DefaultSortHint
}
