import AppKit
import ImageIO
import os

/// Decodes scene images at display size (spec §10). Library wallpapers are
/// 5K files — decoding them full-size for a saver that runs for hours
/// would hold hundreds of MB per image.
enum SceneImageLoader {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "screensaver")

    /// Rounds a pixel size up to a coarse bucket so resizing a preview
    /// window doesn't re-decode on every frame-size change.
    static func pixelBucket(for pixels: CGFloat) -> Int {
        let step = 256
        return max(step, Int((pixels / CGFloat(step)).rounded(.up)) * step)
    }

    static func downsampledImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            log.error("Cannot decode scene image \(url.path, privacy: .public)")
            return nil
        }
        return image
    }
}

/// The decoded images one scene view is using right now. Holds ONLY what
/// was last asked for (the current background, the preloaded next one,
/// and any icon images) — everything else is released.
@MainActor
final class SceneImageStore: ObservableObject {
    @Published private(set) var images: [URL: CGImage] = [:]

    private var pixelSizes: [URL: Int] = [:]
    private var wanted: Set<URL> = []
    private var wantedPixelSize = 0

    private struct ImageBox: @unchecked Sendable {
        let image: CGImage?
    }

    /// Makes `urls` available at `maxPixelSize`, decoding off the main
    /// thread, and drops every image no longer wanted. An image already
    /// held at another size stays on screen until its replacement lands.
    func prepare(_ urls: [URL], maxPixelSize: Int) async {
        wanted = Set(urls)
        wantedPixelSize = maxPixelSize
        for url in images.keys where !wanted.contains(url) {
            images[url] = nil
            pixelSizes[url] = nil
        }

        for url in urls where pixelSizes[url] != maxPixelSize {
            let box = await Task.detached(priority: .utility) {
                ImageBox(image: SceneImageLoader.downsampledImage(at: url, maxPixelSize: maxPixelSize))
            }.value
            // A newer request may have superseded this one while decoding.
            guard wanted.contains(url), wantedPixelSize == maxPixelSize else { return }
            pixelSizes[url] = maxPixelSize
            images[url] = box.image
        }
    }

    func releaseAll() {
        wanted = []
        images = [:]
        pixelSizes = [:]
    }
}
