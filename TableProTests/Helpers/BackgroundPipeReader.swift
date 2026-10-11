//
//  BackgroundPipeReader.swift
//  TableProTests
//

import Foundation

@testable import TablePro

internal enum BackgroundPipeReader {
    static func everything(from reader: FileHandle, pausingFirst pause: TimeInterval) async -> Data? {
        let descriptor = reader.fileDescriptor
        return await BoundedCall.resultOnItsOwnThread {
            Thread.sleep(forTimeInterval: pause)
            var bytes = Data()
            while let chunk = try? DescriptorRead.availableBytes(from: descriptor), !chunk.isEmpty {
                bytes.append(chunk)
            }
            return bytes
        }
    }
}
