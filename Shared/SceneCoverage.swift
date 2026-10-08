import CoreGraphics
import Foundation

// How much of a clock a subject hides. iOS turns its lock-screen depth
// effect off when the subject would cover too much of the time; Studio
// warns instead, and offers to send the subject behind the clock. All
// pure geometry over a coarse alpha mask, so the composer can run it on
// every edit and the tests can run it on synthetic images.

/// A coarse "is this pixel opaque" grid of an image, row-major with a
/// top-left origin, at most `maxPixelSize` on the long edge.
struct SceneAlphaMask: Equatable {
    let width: Int
    let height: Int
    let opaque: [Bool]

    /// Aspect ratio of the source image (width / height).
    var aspect: CGFloat { height > 0 ? CGFloat(width) / CGFloat(height) : 1 }

    init(width: Int, height: Int, opaque: [Bool]) {
        self.width = width
        self.height = height
        self.opaque = opaque
    }

    /// Samples the image's alpha channel; pixels at least half opaque
    /// count. Nil when the image can't be drawn.
    init?(image: CGImage, maxPixelSize: Int = 128) {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, CGFloat(maxPixelSize) / CGFloat(longEdge))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &alpha, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // A bitmap context's first memory row is the top scanline, so the
        // buffer is already top-down.
        self.init(width: width, height: height, opaque: alpha.map { $0 >= 128 })
    }

    /// Whether the pixel under a unit-space point (0–1, top-left origin)
    /// is opaque; points outside the image are not.
    func isOpaque(atUnitX x: CGFloat, y: CGFloat) -> Bool {
        guard x >= 0, x < 1, y >= 0, y < 1 else { return false }
        let column = min(width - 1, Int(x * CGFloat(width)))
        let row = min(height - 1, Int(y * CGFloat(height)))
        return opaque[row * width + column]
    }
}

enum SceneCoverage {
    /// Above this share of the clock hidden, Studio warns.
    static let warningThreshold: Double = 0.3

    /// The fraction of `rect` that `mask`, drawn into `maskRect`, covers
    /// with opaque pixels — sampled on a `samples × samples` grid, so a
    /// 64-sample pass costs nothing noticeable.
    static func fraction(of rect: CGRect, coveredBy mask: SceneAlphaMask, drawnIn maskRect: CGRect,
                         samples: Int = 64) -> Double {
        guard rect.width > 0, rect.height > 0, maskRect.width > 0, maskRect.height > 0, samples > 0 else { return 0 }
        guard rect.intersects(maskRect) else { return 0 }
        var covered = 0
        for row in 0..<samples {
            let y = rect.minY + (CGFloat(row) + 0.5) / CGFloat(samples) * rect.height
            for column in 0..<samples {
                let x = rect.minX + (CGFloat(column) + 0.5) / CGFloat(samples) * rect.width
                if mask.isOpaque(atUnitX: (x - maskRect.minX) / maskRect.width,
                                 y: (y - maskRect.minY) / maskRect.height) {
                    covered += 1
                }
            }
        }
        return Double(covered) / Double(samples * samples)
    }

    /// Where a subject layer draws on a canvas: pinned, exactly where the
    /// background draws its image (the cutout shares the photo's shape);
    /// free, its crop centred at the layer's position, `size` tall.
    static func subjectRect(_ subject: SubjectLayer, layer: SceneLayer, mask: SceneAlphaMask,
                            treatment: SceneBackgroundTreatment, canvas: CGSize,
                            displayScale: CGFloat) -> (rect: CGRect, maskRect: CGRect) {
        if subject.isPinned {
            let rect = SceneBackgroundGeometry.imageRect(imageSize: CGSize(width: mask.width, height: mask.height),
                                                         canvas: canvas, treatment: treatment,
                                                         displayScale: displayScale)
            return (rect, rect)
        }
        let height = max(1, layer.size * canvas.height)
        let crop = subject.bounds?.pixelRect(in: CGSize(width: mask.width, height: mask.height))
            ?? CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        let width = height * crop.width / max(1, crop.height)
        let rect = CGRect(x: layer.position.x * canvas.width - width / 2,
                          y: layer.position.y * canvas.height - height / 2,
                          width: width, height: height)
        // The whole mask, positioned so its crop lands on `rect`.
        let scale = height / max(1, crop.height)
        let maskRect = CGRect(x: rect.minX - crop.minX * scale, y: rect.minY - crop.minY * scale,
                              width: CGFloat(mask.width) * scale, height: CGFloat(mask.height) * scale)
        return (rect, maskRect)
    }

    /// Rectangle a layer rests in (no motion) on a canvas.
    static func restingRect(center: ScenePoint, size: CGSize, canvas: CGSize) -> CGRect {
        CGRect(x: center.x * canvas.width - size.width / 2,
               y: center.y * canvas.height - size.height / 2,
               width: size.width, height: size.height)
    }
}

/// The rectangle the background image occupies for each fit — the same
/// arithmetic `SceneFrameView.backgroundImage` lays out with.
enum SceneBackgroundGeometry {
    static func imageRect(imageSize: CGSize, canvas: CGSize, treatment: SceneBackgroundTreatment,
                          displayScale: CGFloat) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        switch treatment.scaleMode {
        case .fill:
            let scale = max(canvas.width / imageSize.width, canvas.height / imageSize.height) * treatment.zoom
            return centred(size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale),
                           in: canvas, focus: treatment.focus)
        case .fit, .fitBlur:
            let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
            return centred(size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale),
                           in: canvas, focus: .center)
        case .stretch:
            return CGRect(origin: .zero, size: canvas)
        case .center:
            let scale = treatment.zoom / displayScale
            return centred(size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale),
                           in: canvas, focus: treatment.focus)
        }
    }

    /// Centred, then slid so the focus point is what stays on screen when
    /// the image overflows the canvas on an axis.
    private static func centred(size: CGSize, in canvas: CGSize, focus: ScenePoint) -> CGRect {
        let overflow = CGSize(width: max(0, size.width - canvas.width), height: max(0, size.height - canvas.height))
        return CGRect(x: (canvas.width - size.width) / 2 - (focus.x - 0.5) * overflow.width,
                      y: (canvas.height - size.height) / 2 - (focus.y - 0.5) * overflow.height,
                      width: size.width, height: size.height)
    }
}
