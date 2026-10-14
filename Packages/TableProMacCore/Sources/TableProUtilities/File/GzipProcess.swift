//
//  GzipProcess.swift
//  TablePro
//

import Foundation
import os

private let logger = Logger(subsystem: "com.TablePro", category: "GzipProcess")

enum GzipProcess {
    enum GzipError: LocalizedError {
        case executableNotFound
        case compressionFailed(Int32, String)
        case decompressionFailed(Int32, String)
        case destinationCreateFailed

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return String(localized: "gzip executable not found")
            case .compressionFailed(let status, let message):
                return message.isEmpty
                    ? String(format: String(localized: "Compression failed with exit status %d"), status)
                    : message
            case .decompressionFailed(let status, let message):
                return message.isEmpty
                    ? String(format: String(localized: "Decompression failed with exit status %d"), status)
                    : message
            case .destinationCreateFailed:
                return String(localized: "Could not create destination file")
            }
        }
    }

    static func compress(source: URL, destination: URL) async throws {
        let gzipPath = "/usr/bin/gzip"
        guard FileManager.default.isExecutableFile(atPath: gzipPath) else {
            throw GzipError.executableNotFound
        }

        let sourcePath = source.standardizedFileURL.path(percentEncoded: false)

        guard FileManager.default.createFile(
            atPath: destination.path(percentEncoded: false),
            contents: nil
        ) else {
            throw GzipError.destinationCreateFailed
        }

        let outputHandle = try FileHandle(forWritingTo: destination)
        let errorPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gzipPath)
        process.arguments = ["-c", sourcePath]
        process.standardOutput = outputHandle
        process.standardError = errorPipe

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { proc in
                    try? outputHandle.close()
                    let status = proc.terminationStatus
                    if status == 0 {
                        continuation.resume()
                    } else {
                        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errMsg = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.resume(throwing: GzipError.compressionFailed(status, errMsg))
                    }
                }
                do {
                    try process.run()
                } catch {
                    try? outputHandle.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    static func decompress(source: URL, destination: URL) async throws {
        let gzipPath = "/usr/bin/gzip"
        guard FileManager.default.isExecutableFile(atPath: gzipPath) else {
            throw GzipError.executableNotFound
        }

        let sourcePath = source.standardizedFileURL.path(percentEncoded: false)

        guard FileManager.default.createFile(
            atPath: destination.path(percentEncoded: false),
            contents: nil
        ) else {
            throw GzipError.destinationCreateFailed
        }

        let outputHandle = try FileHandle(forWritingTo: destination)
        let errorPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gzipPath)
        process.arguments = ["-d", "-c", sourcePath]
        process.standardOutput = outputHandle
        process.standardError = errorPipe

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { proc in
                    try? outputHandle.close()
                    let status = proc.terminationStatus
                    if status == 0 {
                        continuation.resume()
                    } else {
                        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errMsg = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.resume(throwing: GzipError.decompressionFailed(status, errMsg))
                    }
                }
                do {
                    try process.run()
                } catch {
                    try? outputHandle.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}
