//
//  String+encoding.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 1/19/23.
//

import Foundation

extension String {
    static var nativeUTF16Encoding: String.Encoding {
        let dataA = "abc".data(using: .utf16LittleEndian)
        let dataB = "abc".data(using: .utf16)?.suffix(from: 2)

        return dataA == dataB ? .utf16LittleEndian : .utf16BigEndian
    }
}
