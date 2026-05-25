//
//  AWSCredentials.swift
//  TablePro
//

import Foundation

struct AWSCredentials: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
}
