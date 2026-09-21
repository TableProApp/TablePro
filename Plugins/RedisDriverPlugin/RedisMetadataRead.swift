//
//  RedisMetadataRead.swift
//  RedisDriverPlugin
//
//  A read the driver makes on its own to describe the server, as opposed to a command the user
//  typed. Managed services remove commands outright (ElastiCache and Azure answer CONFIG with
//  `ERR unknown command`) or deny them by ACL (Memorystore answers `NOPERM`), and neither means
//  the connection failed: the view the read was for should carry on without that answer.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisMetadataRead")

enum RedisMetadataRead {
    /// `ERR` is also what a subscribed session answers for any other command, which is fine to
    /// treat the same way: a degraded list costs less than a view that refuses to open. Every
    /// other class (`BUSY`, `NOAUTH`, `LOADING`, `MASTERDOWN`) is a state the user needs to see.
    static let declinedClasses: Set<String> = ["ERR", "NOPERM"]

    static func declinedClass(of reply: RedisReply) -> String? {
        guard let message = reply.errorMessage else { return nil }
        let errorClass = RedisConnectProbe.errorClass(of: message)
        return declinedClasses.contains(errorClass) ? errorClass : nil
    }
}

extension RedisCommandChannel {
    /// Nil when the server declines the read. Everything else behaves exactly as `run`: a
    /// transport failure and a `-BUSY` throw, and so does an open `MULTI` block, which the read
    /// is held back from rather than sent into.
    func runMetadataRead(_ args: [String]) async throws -> RedisReply? {
        let name = args.first ?? ""
        let reply = try await executeCommand(args, scope: .outsideBlock)
        if let declinedClass = RedisMetadataRead.declinedClass(of: reply) {
            logger.notice("\(name, privacy: .public) declined with \(declinedClass, privacy: .public); continuing without it")
            return nil
        }
        return try reply.throwIfError(name).throwIfQueued(name)
    }
}
