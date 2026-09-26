import Foundation

/// What a write command's reply says went wrong when the command itself ran.
///
/// `mongoc_client_command_simple` answers only whether the server ran the command. An `update`,
/// `delete`, `insert` or `findAndModify` it ran can still refuse the documents it reached, and the
/// server reports that in `writeErrors` or `writeConcernError` under `ok: 1`. Reading `n` alone
/// passed a validator rejection, an immutable `_id` and a duplicate key off as a write that
/// matched nothing.
///
/// A write-concern error arrives after the write itself was applied, so its message says so rather
/// than reading like a refusal. A raw command reply holds one as `writeConcernError`, and the reply
/// libmongoc builds for a CRUD call holds them as a `writeConcernErrors` array.
struct MongoWriteFailure: Equatable, Sendable {
    let code: UInt32
    let message: String

    static func read(fromReply replyJson: String) -> MongoWriteFailure? {
        guard let data = replyJson.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let writeErrors = reply["writeErrors"] as? [[String: Any]], let first = writeErrors.first {
            return entry(first)
        }
        let concernErrors = reply["writeConcernErrors"] as? [[String: Any]]
        if let concernError = reply["writeConcernError"] as? [String: Any] ?? concernErrors?.first {
            let failure = entry(concernError)
            return MongoWriteFailure(
                code: failure.code,
                message: MongoScriptText.writeNotAcknowledged(reason: failure.message)
            )
        }
        return nil
    }

    private static func entry(_ entry: [String: Any]) -> MongoWriteFailure {
        let code = UInt32(clamping: MongoScriptJson.numeric(entry["code"]) ?? 0)
        guard let message = entry["errmsg"] as? String, !message.isEmpty else {
            return MongoWriteFailure(code: code, message: MongoScriptText.writeRefused(code: code))
        }
        return MongoWriteFailure(code: code, message: message)
    }
}
