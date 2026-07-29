//
//  CloudflareTunnelError.swift
//  TablePro
//

import Foundation

/// Errors raised while starting or supervising a cloudflared Access TCP tunnel.
enum CloudflareTunnelError: Error, LocalizedError, Equatable {
    case binaryNotFound
    case noAvailablePort
    case startupFailed(stderrTail: String)
    case readinessTimeout(stderrTail: String)
    case browserAuthRequired(url: String)
    case tunnelAlreadyExists(UUID)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return String(localized: "cloudflared was not found. Install it with `brew install cloudflared`, or set its path in the connection's Cloudflare Tunnel settings.")
        case .noAvailablePort:
            return String(localized: "No available local port for the Cloudflare tunnel.")
        case .startupFailed(let stderrTail):
            return stderrTail.isEmpty
                ? String(localized: "cloudflared failed to start.")
                : String(format: String(localized: "cloudflared failed to start: %@"), stderrTail)
        case .readinessTimeout(let stderrTail):
            return stderrTail.isEmpty
                ? String(localized: "The Cloudflare tunnel did not become ready in time.")
                : String(format: String(localized: "The Cloudflare tunnel did not become ready in time: %@"), stderrTail)
        case .browserAuthRequired(let url):
            return String(format: String(localized: "Cloudflare Access needs a browser sign-in. Sign in at %@, then reconnect."), url)
        case .tunnelAlreadyExists(let id):
            return String(format: String(localized: "A Cloudflare tunnel already exists for connection: %@"), id.uuidString)
        }
    }
}
