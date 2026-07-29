//
//  NaturalSortKey.swift
//  TablePro
//

import Foundation

func naturalSortKey(_ raw: String) -> String {
    let scalars = Array(raw.lowercased().unicodeScalars)
    var result = ""
    result.reserveCapacity(scalars.count + 8)
    var i = 0
    let n = scalars.count
    while i < n {
        let value = scalars[i].value
        if value >= 0x30, value <= 0x39 {
            var runEnd = i
            while runEnd < n, scalars[runEnd].value >= 0x30, scalars[runEnd].value <= 0x39 {
                runEnd += 1
            }
            var sigStart = i
            while sigStart < runEnd, scalars[sigStart].value == 0x30 {
                sigStart += 1
            }
            let length = UInt32(runEnd - sigStart)
            result.unicodeScalars.append(Unicode.Scalar(UInt8(truncatingIfNeeded: 0x30 + (length / 1_000) % 10)))
            result.unicodeScalars.append(Unicode.Scalar(UInt8(truncatingIfNeeded: 0x30 + (length / 100) % 10)))
            result.unicodeScalars.append(Unicode.Scalar(UInt8(truncatingIfNeeded: 0x30 + (length / 10) % 10)))
            result.unicodeScalars.append(Unicode.Scalar(UInt8(truncatingIfNeeded: 0x30 + length % 10)))
            for j in sigStart..<runEnd {
                result.unicodeScalars.append(scalars[j])
            }
            i = runEnd
        } else {
            result.unicodeScalars.append(scalars[i])
            i += 1
        }
    }
    return result
}
