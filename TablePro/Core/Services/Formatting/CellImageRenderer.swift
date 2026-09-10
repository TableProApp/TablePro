//
//  CellImageRenderer.swift
//  TablePro
//
//  Turns a cell's bytes into a bounded preview image.
//

import AppKit
import ImageIO
import os

internal enum CellImageRender: Equatable {
    case rendered(NSImage, pixelSize: CGSize?)
    case tooLarge(byteCount: Int)
    case failed
}

/// The out-of-process half, behind a protocol so a test never depends on spawning the helper.
/// Returns PNG bytes rather than an image, because `NSImage` cannot cross an actor boundary.
internal protocol SvgImageRendering: Sendable {
    func renderPng(from data: Data, maxPixelSize: Int) async -> Data?
}

@MainActor
internal enum CellImageRenderer {
    /// A raster preview never needs more pixels than a pop-out window can show on a Retina display.
    nonisolated static let defaultMaxPixelSize = 2_048

    static var svgRenderer: SvgImageRendering = HelperProcessSvgRenderer()

    static func render(
        _ data: Data,
        format: CellImageFormat,
        maxPixelSize: Int = defaultMaxPixelSize
    ) async -> CellImageRender {
        guard !data.isEmpty else { return .failed }
        guard data.count <= CellImageSniffer.maxPreviewBytes else { return .tooLarge(byteCount: data.count) }

        switch format {
        case .svg:
            guard let png = await svgRenderer.renderPng(from: data, maxPixelSize: maxPixelSize),
                  let image = NSImage(data: png)
            else { return .failed }
            return .rendered(image, pixelSize: nil)
        case .raster:
            guard let decoded = await decodeRaster(data, maxPixelSize: maxPixelSize) else { return .failed }
            let image = NSImage(cgImage: decoded.thumbnail, size: .zero)
            return .rendered(image, pixelSize: decoded.pixelSize)
        }
    }

    /// ImageIO reads the stored dimensions from the header without decoding a pixel, so a
    /// decompression bomb is answered before it can allocate: measured, a 20000x20000 PNG reports
    /// its size in a millisecond and nothing is allocated, while asking for the whole image would
    /// build 1.6 GB. The preview is a thumbnail for the same reason.
    private static func decodeRaster(
        _ data: Data,
        maxPixelSize: Int
    ) async -> (thumbnail: CGImage, pixelSize: CGSize)? {
        await Task.detached(priority: .userInitiated) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }

            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else { return nil }

            let pixelSize = width > 0 && height > 0
                ? CGSize(width: width, height: height)
                : CGSize(width: thumbnail.width, height: thumbnail.height)
            return (thumbnail, pixelSize)
        }.value
    }
}

/// Runs `tablepro-imagerender`, the executable beside the app's own, and gives up on it hard.
///
/// Terminating is the only cancellation that works here. The renderer can be stuck inside a C++
/// recursion that no cooperative check reaches, so the deadline sends `SIGKILL` rather than asking.
internal struct HelperProcessSvgRenderer: SvgImageRendering {
    static let executableName = "tablepro-imagerender"

    /// A benign document rasterizes in 66 ms warm and 530 ms on the first spawn of a session, so
    /// this is generous for anything that is going to answer at all.
    private static let deadlineSeconds: Double = 3

    private static let logger = Logger(subsystem: "com.TablePro", category: "CellImageRenderer")

    func renderPng(from data: Data, maxPixelSize: Int) async -> Data? {
        guard let executable = Self.executableURL() else {
            Self.logger.error("\(Self.executableName, privacy: .public) is missing from the app bundle")
            return nil
        }

        /// A dispatch queue rather than `Task.detached`: the wait below parks its thread for the
        /// whole deadline, and the cooperative pool is only as wide as the core count.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.run(executable: executable, data: data, maxPixelSize: maxPixelSize))
            }
        }
    }

    static func executableURL() -> URL? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    private static func run(executable: URL, data: Data, maxPixelSize: Int) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = [String(maxPixelSize)]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        /// Nothing reads the helper's stderr, and an undrained pipe deadlocks a child that fills it.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("could not start the image renderer: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let png = UnsafeSendableBox<Data>(Data())
        let collected = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            png.value = output.fileHandleForReading.readDataToEndOfFile()
            collected.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }

        if finished.wait(timeout: .now() + deadlineSeconds) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 2)
            logger.notice("the image renderer did not answer within the deadline and was terminated")
        }
        _ = collected.wait(timeout: .now() + 2)
        try? output.fileHandleForReading.close()

        guard process.terminationStatus == 0, !png.value.isEmpty else { return nil }
        return png.value
    }
}

/// One value handed between the reader queue and the caller, guarded by the semaphore they share.
private final class UnsafeSendableBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
