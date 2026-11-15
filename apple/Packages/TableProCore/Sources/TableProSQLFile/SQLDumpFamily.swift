import Foundation

// The client a dump was written for, which decides the statements an import rewrites before it sends them.
public enum SQLDumpFamily: Sendable, Hashable, CaseIterable {
    case mysql
    case postgres
    case other
}
