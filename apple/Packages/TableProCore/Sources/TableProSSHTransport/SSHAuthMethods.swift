//
//  SSHAuthMethods.swift
//  TableProSSHTransport
//

import Foundation

public enum SSHAuthMethods {
    public static func parse(_ list: String?) -> [String] {
        guard let list else { return [] }
        return list
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // libssh2 never reads the partial-success flag, so an accepted method that needs another step
    // shows only as that method leaving the server's list.
    public static func remainingAfterPartialSuccess(of method: String, before: [String], after: [String]) -> [String]? {
        guard before.contains(method), !after.isEmpty, !after.contains(method) else { return nil }
        return after
    }
}
