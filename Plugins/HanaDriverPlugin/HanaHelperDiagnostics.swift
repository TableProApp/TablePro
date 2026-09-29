import Darwin
import Foundation
import os

struct HanaHelperOutputTail: Sendable {
    static let defaultLimit = 4_096

    let limit: Int
    private(set) var bytes = Data()

    init(limit: Int = HanaHelperOutputTail.defaultLimit) {
        self.limit = limit
    }

    mutating func append(_ chunk: Data) {
        bytes.append(chunk)
        guard bytes.count > limit else { return }
        bytes = Data(bytes.suffix(limit))
    }

    var text: String {
        String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HanaHelperDuration {
    static func secondsText(_ seconds: TimeInterval) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(seconds)
    }
}

struct HanaHelperExitReport: Equatable, Sendable {
    enum Termination: Equatable, Sendable {
        case exited(status: Int32)
        case signalled(Int32)
        case unknown
    }

    let termination: Termination
    let stopCause: String?
    let errorTail: String

    var summary: String {
        let ending: String
        switch termination {
        case .exited(let status):
            ending = "The SAP HANA helper exited with status \(status)."
        case .signalled(let signal):
            ending = "The SAP HANA helper was stopped by signal \(signal)."
        case .unknown:
            ending = "The SAP HANA helper closed its output."
        }
        guard let stopCause else { return ending }
        return stopCause + " " + ending
    }

    var message: String {
        guard !errorTail.isEmpty else { return summary }
        return summary + "\n" + errorTail
    }
}

final class HanaHelperErrorStream: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "HanaHelperProcess")
    private static let chunkSize = 4_096

    private let lock = NSLock()
    private let drained = DispatchSemaphore(value: 0)
    private var tail = HanaHelperOutputTail()

    func drain(_ handle: FileHandle, helper processIdentifier: pid_t) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            let received = Darwin.read(descriptor, &buffer, buffer.count)
            if received < 0, errno == EINTR {
                continue
            }
            guard received > 0 else { break }
            let chunk = Data(buffer[0..<received])
            lock.withLock { tail.append(chunk) }
            let text = String(decoding: chunk, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
            Self.logger.error("SAP HANA helper \(processIdentifier) wrote: \(text, privacy: .private)")
        }
        drained.signal()
    }

    func tailText(waitingUntil deadline: DispatchTime) -> String {
        if drained.wait(timeout: deadline) == .success {
            drained.signal()
        }
        return lock.withLock { tail.text }
    }
}
