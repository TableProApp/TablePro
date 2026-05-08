//
//  JSONValue+Encoding.swift
//  TablePro
//

import Foundation

extension JSONValue {
    func asJSONObject() throws -> Any {
        let data = try JSONEncoder().encode(self)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    func asJSONString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}
