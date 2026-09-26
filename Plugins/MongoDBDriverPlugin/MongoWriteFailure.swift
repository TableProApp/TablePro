import Foundation

/// What a write command's reply says went wrong.
///
/// `mongoc_client_command_simple` answers only whether the server ran the command. An `update`,
/// `delete`, `insert` or `findAndModify` it ran can still refuse the documents it reached, and the
/// server reports that in `writeErrors` or `writeConcernError` under `ok: 1`. Reading `n` alone
/// passed a validator rejection, an immutable `_id` and a duplicate key off as a write that
/// matched nothing.
///
/// A write-concern error arrives after the write itself was applied, so its message says so rather
/// than reading like a refusal.
///
/// The stage says how far the write got, which is what decides whether documents may already have
/// changed. A command the server stopped while it ran (`ok: 0` with a code in the `Interruption`
/// category) keeps what it had written, and the reply does not say how much. That test reads the
/// code from the reply, never from libmongoc's error, whose own `24` and `50` mean something else.
///
/// It is also the error the host throws for a failed write, and the stage crosses into the script
/// with it. That is how the driver tells a write's failure from a read's when both carry the same
/// code and message: a script can catch one and go on to fail on the other.
struct MongoWriteFailure: Error, LocalizedError, Equatable, Sendable {
    enum Stage: String, Equatable, Sendable {
        case document
        case unconfirmed
        case command
        case unanswered
        case notSent
        /// An insert that sent some batches and then met a document it could not send.
        case stoppedBetweenBatches
    }

    let code: UInt32
    let message: String
    let stage: Stage

    var errorDescription: String? { message }

    var stoppedWhileRunning: Bool {
        stage == .command && MongoDBServerErrorCode.interruptionCategory.contains(code)
    }

    /// Reads the raw command reply, and the reply the CRUD calls build, which carries
    /// `writeConcernErrors` and `errorReplies` as arrays and has no `ok` of its own.
    static func read(fromReply replyJson: String) -> MongoWriteFailure? {
        guard let data = replyJson.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let writeErrors = reply["writeErrors"] as? [[String: Any]], let first = writeErrors.first {
            return entry(first, stage: .document)
        }
        if let concernError = reply["writeConcernError"] as? [String: Any]
            ?? (reply["writeConcernErrors"] as? [[String: Any]])?.first {
            let failure = entry(concernError, stage: .unconfirmed)
            return MongoWriteFailure(
                code: failure.code,
                message: MongoScriptText.writeNotAcknowledged(reason: failure.message),
                stage: .unconfirmed
            )
        }
        if MongoScriptJson.numeric(reply["ok"]) == 0 {
            return entry(reply, stage: .command)
        }
        if let errorReply = (reply["errorReplies"] as? [[String: Any]])?.first {
            return entry(errorReply, stage: .command)
        }
        return nil
    }

    private static func entry(_ entry: [String: Any], stage: Stage) -> MongoWriteFailure {
        let code = UInt32(clamping: MongoScriptJson.numeric(entry["code"]) ?? 0)
        guard let message = entry["errmsg"] as? String, !message.isEmpty else {
            return MongoWriteFailure(code: code, message: MongoScriptText.writeRefused(code: code), stage: stage)
        }
        return MongoWriteFailure(code: code, message: message, stage: stage)
    }
}

/// One write's reply, kept whether or not the write failed, because a failed write can still have
/// changed documents and the reply is the only record of how many.
struct MongoWriteOutcome: Sendable {
    let replyJson: String
    let failure: MongoWriteFailure?
}
