//
//  DescriptorWrite.swift
//  TablePro
//

import Darwin
import Foundation

internal enum DescriptorWrite {
    static func allBytes(_ bytes: Data, to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, start + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                    continue
                }
                let failure = errno
                if failure == EAGAIN {
                    try waitForRoom(descriptor)
                    continue
                }
                try throwUnlessInterrupted(failure)
            }
        }
    }

    private static func waitForRoom(_ descriptor: Int32) throws {
        var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        while poll(&request, 1, -1) == -1 {
            try throwUnlessInterrupted(errno)
        }
    }

    private static func throwUnlessInterrupted(_ failure: Int32) throws {
        guard failure == EINTR else {
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }
}
