//
//  ChatImageConverter.swift
//  TablePro
//

import AppKit
import CoreServices
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

enum ChatImageConverterError: Error, LocalizedError {
    case unsupportedFormat
    case decodingFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return String(localized: "Unsupported image format")
        case .decodingFailed:    return String(localized: "Could not decode image")
        case .encodingFailed:    return String(localized: "Could not encode image")
        }
    }
}

enum ChatImageConverter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ChatImageConverter")

    static let maxLongEdgePixels: CGFloat = 2_000
    static let jpegQuality: CGFloat = 0.92

    static func convert(fileURL url: URL) async throws -> ChatImageInput {
        if url.scheme == "http" || url.scheme == "https" {
            let mediaType = mediaType(forExtension: url.pathExtension)
            return ChatImageInput(source: .remoteURL(url, mediaType: mediaType))
        }
        let data = try Data(contentsOf: url)
        return try await convert(data: data, sourceUTI: nil)
    }

    static func convert(itemProvider: NSItemProvider) async throws -> ChatImageInput {
        if itemProvider.canLoadObject(ofClass: NSImage.self) {
            let image: NSImage = try await loadObject(itemProvider: itemProvider)
            return try encode(nsImage: image)
        }
        if let typeIdentifier = itemProvider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) ?? false }) {
            let data = try await loadData(itemProvider: itemProvider, typeIdentifier: typeIdentifier)
            return try await convert(data: data, sourceUTI: typeIdentifier)
        }
        throw ChatImageConverterError.unsupportedFormat
    }

    static func convert(data: Data, sourceUTI: String?) async throws -> ChatImageInput {
        try await Task.detached(priority: .userInitiated) {
            try encodeData(data, sourceUTI: sourceUTI)
        }.value
    }

    private static func encodeData(_ data: Data, sourceUTI: String?) throws -> ChatImageInput {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ChatImageConverterError.decodingFailed
        }
        let detectedType = (CGImageSourceGetType(source) as String?) ?? sourceUTI ?? UTType.image.identifier
        let useJPEG = preferJPEG(forUTI: detectedType)
        return try encode(source: source, useJPEG: useJPEG)
    }

    private static func encode(nsImage: NSImage) throws -> ChatImageInput {
        guard let tiff = nsImage.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil) else {
            throw ChatImageConverterError.encodingFailed
        }
        return try encode(source: source, useJPEG: false)
    }

    private static func encode(source: CGImageSource, useJPEG: Bool) throws -> ChatImageInput {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ChatImageConverterError.decodingFailed
        }
        let scaledImage = redrawInSRGB(cgImage)
        let targetType: CFString = useJPEG ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString
        let mediaType = useJPEG ? "image/jpeg" : "image/png"
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, targetType, 1, nil) else {
            throw ChatImageConverterError.encodingFailed
        }
        var properties: [CFString: Any] = [:]
        if useJPEG {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        CGImageDestinationAddImage(destination, scaledImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ChatImageConverterError.encodingFailed
        }
        let data = output as Data
        let filename = AIImageCache.shared.store(data: data, mediaType: mediaType)
        return ChatImageInput(source: .cacheFile(filename: filename, mediaType: mediaType))
    }

    /// Always re-draws into a premultiplied-RGBA sRGB context. Strips ICC/IPTC
    /// metadata carried on the source CGImage (CMYK TIFF, HEIC with embedded
    /// EXIF), and downscales to `maxLongEdgePixels` when needed.
    private static func redrawInSRGB(_ image: CGImage) -> CGImage {
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        let longEdge = max(srcW, srcH)
        let scale = longEdge > maxLongEdgePixels ? maxLongEdgePixels / longEdge : 1
        let width = max(1, Int(srcW * scale))
        let height = max(1, Int(srcH * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func preferJPEG(forUTI uti: String) -> Bool {
        guard let type = UTType(uti) else { return false }
        if type.conforms(to: .png) { return false }
        if type.conforms(to: .jpeg) { return true }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return true }
        if type.conforms(to: .tiff) || type.conforms(to: .bmp) { return false }
        return false
    }

    private static func mediaType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        default:     return "image/png"
        }
    }

    private static func loadObject<T: NSItemProviderReading>(itemProvider: NSItemProvider) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadObject(ofClass: T.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let typed = object as? T else {
                    continuation.resume(throwing: ChatImageConverterError.decodingFailed)
                    return
                }
                continuation.resume(returning: typed)
            }
        }
    }

    private static func loadData(itemProvider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: ChatImageConverterError.decodingFailed)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
