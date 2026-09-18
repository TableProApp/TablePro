//
//  CommitOutcomeDiagnosisTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Commit outcome diagnosis")
struct CommitOutcomeDiagnosisTests {
    /// The sentences the engines actually produce when the socket went before the answer did.
    @Test(
        "A commit whose connection died reports an unknown outcome",
        arguments: [
            "MySQL server has gone away",
            "Lost connection to MySQL server during query",
            "Lost connection to server at 'reading initial communication packet'",
            "server closed the connection unexpectedly",
            "no connection to the server",
            "SSL SYSCALL error: EOF detected",
            "SSL connection has been closed unexpectedly",
            "connection not open",
            "Connection reset by peer",
            "Broken pipe",
            "terminating connection due to administrator command",
            "Operation timed out",
        ]
    )
    func connectionLossIsRecognised(message: String) {
        #expect(CommitOutcomeDiagnosis.isConnectionLoss(DatabaseError.queryFailed(message)))
    }

    /// A commit the server refused is an answer, and the rollback that follows one is honest. These
    /// must not be reported as unknown, or every deferred-constraint failure would tell the user to
    /// go and check the table.
    @Test(
        "A commit the server answered is not an unknown outcome",
        arguments: [
            "could not serialize access due to concurrent update",
            "deadlock detected",
            "insert or update on table \"orders\" violates foreign key constraint",
            "cannot commit - no transaction is active",
            "Query execution was interrupted",
            "Duplicate entry '1' for key 'PRIMARY'",
        ]
    )
    func serverAnswersAreNotConnectionLoss(message: String) {
        #expect(CommitOutcomeDiagnosis.isConnectionLoss(DatabaseError.queryFailed(message)) == false)
    }

    @Test("A driver that threw notConnected reports an unknown outcome")
    func notConnectedIsConnectionLoss() {
        #expect(CommitOutcomeDiagnosis.isConnectionLoss(DatabaseError.notConnected))
    }

    @Test(
        "A POSIX socket failure reports an unknown outcome",
        arguments: [EPIPE, ECONNRESET, ETIMEDOUT, ENOTCONN]
    )
    func posixSocketFailuresAreConnectionLoss(code: Int32) {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        #expect(CommitOutcomeDiagnosis.isConnectionLoss(error))
    }

    @Test("A POSIX failure that is not the socket going is not connection loss")
    func unrelatedPosixFailureIsNotConnectionLoss() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(CommitOutcomeDiagnosis.isConnectionLoss(error) == false)
    }

    @Test("An HTTP driver's lost connection reports an unknown outcome")
    func urlConnectionLossIsRecognised() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        #expect(CommitOutcomeDiagnosis.isConnectionLoss(error))
    }

    @Test("An error carrying no message at all is not read as a connection loss")
    func opaqueErrorIsNotConnectionLoss() {
        #expect(CommitOutcomeDiagnosis.isConnectionLoss(OpaqueError.refused) == false)
    }
}

private enum OpaqueError: Error {
    case refused
}
