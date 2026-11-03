import SwiftUI
import ImageIO
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformImage = NSImage
typealias PlatformFontDescriptor = NSFontDescriptor
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformImage = UIImage
typealias PlatformFontDescriptor = UIFontDescriptor
#endif

extension PlatformColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let hasAlpha = s.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    func withAlpha(_ a: CGFloat) -> PlatformColor { withAlphaComponent(a) }
}

extension PlatformFont {
    func withTraits(bold: Bool = false, italic: Bool = false) -> PlatformFont {
        #if os(macOS)
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let d = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: d, size: pointSize) ?? self
        #else
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let d = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: d, size: pointSize)
        #endif
    }

    static func monospaced(size: CGFloat, weight: PlatformFont.Weight = .regular) -> PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    static func fromData(_ data: Data) -> PlatformImage? { PlatformImage(data: data) }

    var pixelSize: CGSize {
        #if os(macOS)
        if let rep = representations.first, rep.pixelsWide > 0 { return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        return size
        #else
        return CGSize(width: size.width * scale, height: size.height * scale)
        #endif
    }

    #if os(macOS)
    /// Mirrors `UIImage.pngData()`.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    #endif

    func jpegData(quality: CGFloat) -> Data? {
        #if os(macOS)
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #else
        return self.jpegData(compressionQuality: quality)
        #endif
    }

    var cgImageValue: CGImage? {
        #if os(macOS)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }

    /// Downscaled copy whose longest side is at most `maxDimension` points.
    func thumbnail(maxDimension: CGFloat) -> PlatformImage {
        let s = size
        let scale = min(1, maxDimension / max(s.width, s.height, 1))
        if scale >= 1 { return self }
        let target = CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        #if os(macOS)
        let img = NSImage(size: target)
        img.lockFocus()
        draw(in: CGRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        img.unlockFocus()
        return img
        #else
        return UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
        #endif
    }
}

/// ImageIO-based decoding. Downsampling while decoding is several times faster than a full
/// decode plus redraw, and it never materialises the full-size bitmap.
enum ImageLoader {
    private static func options(maxPixels: CGFloat) -> CFDictionary {
        [kCGImageSourceCreateThumbnailFromImageAlways: true,
         kCGImageSourceCreateThumbnailWithTransform: true,
         kCGImageSourceShouldCacheImmediately: true,
         kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
    }

    private static func image(from source: CGImageSource, maxPixels: CGFloat) -> PlatformImage? {
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options(maxPixels: maxPixels)) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }

    static func downsampled(url: URL, maxPixels: CGFloat) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return image(from: source, maxPixels: maxPixels)
    }

    /// Re-encodes an image as JPEG no larger than `maxPixels` on its longest side.
    static func reencodedJPEG(_ data: Data, maxPixels: CGFloat, quality: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options(maxPixels: maxPixels)) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

enum Haptics {
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

enum DeviceInfo {
    static var name: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}

extension View {
    @ViewBuilder func iOSOnly<V: View>(_ transform: (Self) -> V) -> some View {
        #if os(iOS)
        transform(self)
        #else
        self
        #endif
    }

    @ViewBuilder func macOSOnly<V: View>(_ transform: (Self) -> V) -> some View {
        #if os(macOS)
        transform(self)
        #else
        self
        #endif
    }
}

func openExternalURL(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}

func copyToPasteboard(_ string: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #else
    UIPasteboard.general.string = string
    #endif
}
