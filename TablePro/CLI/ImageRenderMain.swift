import AppKit
import Foundation

/// A signal handler has to be a C function pointer, which cannot reach a type's members, so the
/// code it exits with lives at file scope beside the rest of them.
private let couldNotDecode: Int32 = 3
private let unusableSize: Int32 = 4
private let couldNotRasterize: Int32 = 5
private let notAVectorDocument: Int32 = 6
private let stackExhausted: Int32 = 70

/// Rasterizes one untrusted image document and exits.
///
/// This exists as a separate executable because `NSImage(data:)` cannot be trusted with an SVG from
/// a database. A `<use href="#a">` inside `<g id="a">` sends `CGSVGDocumentCreateFromData` into
/// unbounded recursion and blows the stack: measured, a 147-byte document takes the whole process
/// down with SIGSEGV, and a cycle-free chain of nested `<use>` elements expands exponentially and
/// never finishes. Neither is recoverable in process, and no input cap avoids them, so the parse
/// happens where a crash costs a subprocess and the caller's timeout can end a hang.
///
/// stdin carries the document, stdout carries a PNG, and the exit code says what went wrong.
@main
enum ImageRenderTool {
    static func main() {
        installStackGuard()

        let maxPixelSize = CGFloat(Int(CommandLine.arguments.dropFirst().first ?? "") ?? 1_024)
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard !input.isEmpty else { exit(couldNotDecode) }
        guard SvgDocumentGate.isVectorDocument(input) else { exit(notAVectorDocument) }
        guard let image = NSImage(data: input) else { exit(couldNotDecode) }

        let natural = image.size
        guard natural.width.isFinite, natural.height.isFinite, natural.width > 0, natural.height > 0 else {
            exit(unusableSize)
        }

        let scale = min(1, min(maxPixelSize / natural.width, maxPixelSize / natural.height))
        let width = max(1, Int((natural.width * scale).rounded()))
        let height = max(1, Int((natural.height * scale).rounded()))

        guard let png = rasterize(image, width: width, height: height) else { exit(couldNotRasterize) }
        FileHandle.standardOutput.write(png)
    }

    private static func rasterize(_ image: NSImage, width: Int, height: Int) -> Data? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:])
    }

    /// A stack overflow raises SIGSEGV on a stack that has no room left to run a handler, so the
    /// handler needs a stack of its own. With one, the tool reports "could not render" and leaves
    /// no crash report behind; without it the recursion above writes one on every hostile value.
    ///
    /// `sigaltstack` copies the descriptor, so only the buffer has to outlive this call, and it is
    /// never freed because the process exits from the handler that uses it.
    private static func installStackGuard() {
        let size = Int(SIGSTKSZ) * 4
        var alternateStack = stack_t()
        alternateStack.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        alternateStack.ss_size = size
        alternateStack.ss_flags = 0
        sigaltstack(&alternateStack, nil)

        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in _exit(stackExhausted) }
        action.sa_flags = Int32(SA_ONSTACK)
        sigemptyset(&action.sa_mask)
        sigaction(SIGSEGV, &action, nil)
        sigaction(SIGBUS, &action, nil)
    }
}
