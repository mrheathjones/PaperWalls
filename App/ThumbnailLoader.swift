import AppKit
import ImageIO

/// Downsamples images to grid-thumbnail size off the main thread.
/// Bundled wallpapers ship a small thumbnail file, so this mostly matters for
/// external-folder wallpapers where only the full-size image exists.
enum ThumbnailLoader {
    private static let cache = NSCache<NSURL, NSImage>()

    /// NSImage only gains Sendable on macOS 14; this wrapper lets the result
    /// cross the task boundary warning-free on the 13.0 deployment target.
    private struct ImageBox: @unchecked Sendable {
        let image: NSImage?
    }

    static func loadThumbnail(for url: URL, maxPixelSize: Int = 600) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        let box = await Task.detached(priority: .utility) {
            ImageBox(image: thumbnail(for: url, maxPixelSize: maxPixelSize))
        }.value
        return box.image
    }

    private static func thumbnail(for url: URL, maxPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
