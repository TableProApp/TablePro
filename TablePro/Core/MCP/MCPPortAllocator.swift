import Foundation

internal enum MCPPortAllocatorError: Error, LocalizedError {
    case everyCandidateRejected(lastFailure: String)

    internal var errorDescription: String? {
        switch self {
        case .everyCandidateRejected(let lastFailure):
            return String(
                format: String(localized: "The MCP server could not bind a port (%@)"),
                lastFailure
            )
        }
    }
}

internal enum MCPPortAllocator {
    internal static let kernelAssigned: UInt16 = 0

    internal static func candidates(preferred: Int) -> [UInt16] {
        guard let port = UInt16(exactly: preferred), port > 0 else {
            return [kernelAssigned]
        }
        return [port, kernelAssigned]
    }
}
