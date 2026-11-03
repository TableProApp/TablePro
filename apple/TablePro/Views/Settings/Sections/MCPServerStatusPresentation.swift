//
//  MCPServerStatusPresentation.swift
//  TablePro
//

import Foundation
import TableProMCP

internal struct MCPServerStatusPresentation: Equatable {
    let status: IntegrationStatus
    let title: String
    let detail: String?
    let offersRetry: Bool

    internal init(state: MCPServerState, configuredPort: Int) {
        switch state {
        case .stopped:
            status = .stopped
            title = String(localized: "Stopped")
            detail = nil
            offersRetry = false
        case .starting:
            status = .starting
            title = String(localized: "Starting…")
            detail = nil
            offersRetry = false
        case .running(let port):
            status = .running
            title = String(format: String(localized: "Running on port %d"), Int(port))
            // The server falls back to a port the system picks; a client set up for the configured one
            // would not reach it.
            detail = configuredPort > 0 && Int(port) != configuredPort
                ? String(format: String(localized: "Port %d was in use."), configuredPort)
                : nil
            offersRetry = false
        case .failed(let failure):
            status = .failed
            offersRetry = true
            switch failure {
            case .socketFolderUnusable:
                title = String(localized: "Couldn't start")
                detail = String(localized: "The MCP server could not prepare its private socket folder.")
            case .listenerUnavailable(let reason):
                title = String(localized: "Couldn't start")
                detail = MCPPortAllocatorError.everyCandidateRejected(lastFailure: reason).localizedDescription
            case .noBoundPort:
                title = String(localized: "Couldn't start")
                detail = String(localized: "The MCP server started without a port.")
            case .credentialUnavailable:
                title = String(localized: "Couldn't start")
                detail = String(localized: "The MCP server could not issue its bridge credential.")
            case .listenerStopped(let reason):
                title = String(localized: "Stopped unexpectedly")
                detail = reason.isEmpty ? nil : reason
            }
        }
    }
}
