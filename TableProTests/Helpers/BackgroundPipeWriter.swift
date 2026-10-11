//
//  BackgroundPipeWriter.swift
//  TableProTests
//

import Darwin
import Foundation

internal enum BackgroundPipeWriter {
    static func write(_ chunks: [Data], to writer: FileHandle, pausingBeforeEach pause: TimeInterval) {
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        Thread.detachNewThread {
            for chunk in chunks {
                Thread.sleep(forTimeInterval: pause)
                try? writer.write(contentsOf: chunk)
            }
            try? writer.close()
        }
    }
}
