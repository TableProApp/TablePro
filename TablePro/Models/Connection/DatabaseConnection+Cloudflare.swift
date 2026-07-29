//
//  DatabaseConnection+Cloudflare.swift
//  TablePro
//

extension DatabaseConnection {
    /// Whether this connection routes through a Cloudflare Access TCP tunnel.
    var isCloudflareEnabled: Bool {
        if case .inline = cloudflareTunnelMode { return true }
        return false
    }

    /// The resolved Cloudflare configuration, or nil when tunneling is disabled.
    var resolvedCloudflareConfig: CloudflareConfiguration? {
        if case .inline(let config) = cloudflareTunnelMode { return config }
        return nil
    }
}
