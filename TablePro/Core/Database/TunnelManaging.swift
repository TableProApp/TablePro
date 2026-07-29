//
//  TunnelManaging.swift
//  TablePro
//

import Foundation

protocol TunnelManaging: AnyObject, Sendable {
    func closeTunnel(connectionId: UUID) async throws
    func hasTunnel(connectionId: UUID) async -> Bool
}
