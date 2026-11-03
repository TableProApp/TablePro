//
//  ServerEndpointFields.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The plugin-declared fields that name the server a driver dials, for a type that keeps it
/// there instead of in the built-in Host and Port.
///
/// DuckDB's Remote mode reads `duckdbHost` and `duckdbPort` and never `config.host`, so a tunnel
/// that forwarded the built-in Host carried nothing the driver used. Curated per type for the
/// reason `LocalFilePathField` is: an older bundle has no static to read, and the field ids it
/// already declares are enough to forward and rewrite.
struct ServerEndpointFields: Sendable, Equatable, Hashable {
    let hostFieldId: String
    let portFieldId: String
}

extension PluginMetadataSnapshot {
    /// The server fields these values put to use. A DuckDB row in Local File mode keeps the host
    /// it had in Remote in a hidden field, and dials nothing.
    func activeServerEndpointFields(forValues values: [String: String]) -> ServerEndpointFields? {
        guard let endpointFields = capabilities.serverEndpointFields else { return nil }
        let declared = connection.additionalConnectionFields
        guard let hostField = declared.first(where: { $0.id == endpointFields.hostFieldId }),
              declared.isVisible(hostField, forValues: values)
        else { return nil }
        return endpointFields
    }

    /// Whether the driver dials a TCP endpoint that a forwarded loopback port can stand in for.
    ///
    /// An `.apiOnly` or `.fileBased` driver reaches its database through an SDK, a URL it builds
    /// itself or a path, so a port forward there opens a tunnel nothing uses and the driver goes
    /// around it. A `.network` driver always dials `config.host`.
    func dialsForwardedEndpoint(forValues values: [String: String]) -> Bool {
        connectionMode == .network || activeServerEndpointFields(forValues: values) != nil
    }
}
