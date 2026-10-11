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

    /// The image bytes alone, for a wire format that takes base64 rather than a URL. A remote
    /// image has none to give without a download.
    func base64Payload() -> String? {
        guard case .cacheFile(let filename, _) = source else { return nil }
        return AIImageCache.shared.read(filename: filename)?.base64EncodedString()
    }
}

enum DetailHint: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, low, high

    var id: String { rawValue }
}
