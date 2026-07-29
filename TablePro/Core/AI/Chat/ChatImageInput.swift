//
//  ChatImageInput.swift
//  TablePro
//

import Foundation

struct ChatImageInput: Codable, Equatable, Sendable {
    enum Source: Codable, Equatable, Sendable {
        case cacheFile(filename: String, mediaType: String)
        case remoteURL(URL, mediaType: String)
    }

    var source: Source
    var detailHint: DetailHint

    init(source: Source, detailHint: DetailHint = .auto) {
        self.source = source
        self.detailHint = detailHint
    }

    var mediaType: String {
        switch source {
        case .cacheFile(_, let mediaType): return mediaType
        case .remoteURL(_, let mediaType): return mediaType
        }
    }

    func imageURLString() -> String? {
        switch source {
        case .cacheFile(let filename, let mediaType):
            guard let data = AIImageCache.shared.read(filename: filename) else { return nil }
            return "data:\(mediaType);base64,\(data.base64EncodedString())"
        case .remoteURL(let url, _):
            return url.absoluteString
        }
    }
}

enum DetailHint: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, low, high

    var id: String { rawValue }
}
