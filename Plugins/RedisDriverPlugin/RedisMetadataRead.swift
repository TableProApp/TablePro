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

    /// Nil when the server declined, the reply itself when it answered, and a throw for every
    /// other error and for a `+QUEUED` acknowledgement, labelled with the command.
    static func answer(_ reply: RedisReply, to command: String) throws -> RedisReply? {
        guard declinedClass(of: reply) == nil else { return nil }
        return try reply.throwIfError(command).throwIfQueued(command)
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
        }
        return try RedisMetadataRead.answer(reply, to: name)
    }

    /// The same rule over one pipeline, one answer per command in the order they were sent. A key
    /// the user's ACL does not cover is declined on its own (`-NOPERM No permissions to access a
    /// key`) while the keys around it answer, so a refusal stays in its own place instead of
    /// failing the batch or reading as a value.
    func runMetadataReads(_ commands: [[String]]) async throws -> [RedisReply?] {
        guard !commands.isEmpty else { return [] }
        let replies = try await executePipeline(commands, scope: .outsideBlock)
        let answers = try zip(commands, replies).map { command, reply in
            try RedisMetadataRead.answer(reply, to: command.first ?? "")
        }
        noteDeclined(commands: commands, answers: answers)
        return answers
    }

    private func noteDeclined(commands: [[String]], answers: [RedisReply?]) {
        let declined = zip(commands, answers).compactMap { command, answer -> String? in
            answer == nil ? command.first ?? "" : nil
        }
        guard !declined.isEmpty else { return }
        let names = Set(declined).sorted().joined(separator: ", ")
        logger.notice(
            "\(declined.count, privacy: .public) of \(commands.count, privacy: .public) reads declined (\(names, privacy: .public)); continuing without them"
        )
    }
}
