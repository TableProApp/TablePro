//
//  CLIToolVersionProbe.swift
//  TablePro
//

import Foundation
import os

enum CLIToolVersionProbe {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CLIToolVersionProbe")

    static let defaultTimeout: TimeInterval = 3

    static let outputCap = 64 * 1_024

    static func versionOutput(of path: String, timeout: TimeInterval = defaultTimeout) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = CLIToolEnvironment.augmented()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            logger.warning(
                "\(path, privacy: .private(mask: .hash)) did not answer --version within \(timeout, privacy: .public)s"
            )
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = DescriptorRead.bufferedBytes(from: pipe.fileHandleForReading.fileDescriptor, upTo: outputCap)
        return String(data: output, encoding: .utf8)
    }
}
