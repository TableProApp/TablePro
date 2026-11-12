//
//  LibPQParameterBuffers.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

// The C buffers `PQexecParams` and `PQsendQueryParams` read the parameters from: text as a C string, bytes in binary
// format, null as a null pointer.
internal enum LibPQParameterBuffers {
    // libpq reads the buffers only while the call sends them, so they live for `body` alone.
    static func with<T>(
        _ parameters: [PluginCellValue],
        _ body: (_ values: [UnsafePointer<CChar>?], _ lengths: UnsafePointer<Int32>?, _ formats: UnsafePointer<Int32>?) throws -> T
    ) throws -> T {
        var values: [UnsafePointer<CChar>?] = []
        var lengths: [Int32] = []
        var formats: [Int32] = []
        var allocations: [UnsafeMutableRawPointer] = []
        defer {
            for pointer in allocations {
                free(pointer)
            }
        }
        values.reserveCapacity(parameters.count)
        lengths.reserveCapacity(parameters.count)
        formats.reserveCapacity(parameters.count)

        for parameter in parameters {
            switch parameter {
            case .null:
                values.append(nil)
                lengths.append(0)
                formats.append(0)
            case .text(let text):
                guard let cString = strdup(text) else {
                    throw LibPQPluginError(message: "Failed to allocate parameter buffer", sqlState: nil, detail: nil)
                }
                allocations.append(UnsafeMutableRawPointer(cString))
                values.append(UnsafePointer(cString))
                lengths.append(0)
                formats.append(0)
            case .bytes(let data):
                let byteCount = data.count
                guard let raw = malloc(max(byteCount, 1)) else {
                    throw LibPQPluginError(message: "Failed to allocate parameter buffer", sqlState: nil, detail: nil)
                }
                allocations.append(raw)
                if byteCount > 0 {
                    data.copyBytes(to: raw.assumingMemoryBound(to: UInt8.self), count: byteCount)
                }
                values.append(UnsafePointer(raw.assumingMemoryBound(to: CChar.self)))
                lengths.append(Int32(byteCount))
                formats.append(1)
            }
        }

        return try lengths.withUnsafeBufferPointer { lengthsBuffer in
            try formats.withUnsafeBufferPointer { formatsBuffer in
                try body(values, lengthsBuffer.baseAddress, formatsBuffer.baseAddress)
            }
        }
    }
}
