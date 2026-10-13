//
//  OffscreenRender.swift
//  TableProTests
//

import AppKit
import SwiftUI

@MainActor
internal enum OffscreenRender {
    /// Not `ImageRenderer.cgImage`: it reuses an uncleared buffer, so a view that draws nothing reads back the last render.
    static func bitmap(of view: some View, colorScheme: ColorScheme, scale: CGFloat = 1) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, colorScheme))
        var image: CGImage?
        renderer.render(rasterizationScale: scale) { size, draw in
            let width = Int((size.width * scale).rounded(.up))
            let height = Int((size.height * scale).rounded(.up))
            guard width > 0, height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            draw(context)
            image = context.makeImage()
        }
        return image.map(NSBitmapImageRep.init(cgImage:))
    }
}
