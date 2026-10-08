import SwiftUI
import XCTest

/// Renders one frame with a photo background and its pinned subject and
/// reads pixels back: the cutout must land exactly on the photo, cover
/// what is below it in the layer list, and let layers above it through.
@MainActor
final class SubjectRenderTests: XCTestCase {
    private let canvas = CGSize(width: 400, height: 250)
    /// The "photo": a sky-blue field with a brown block in the middle —
    /// and the "cutout": the same block on a transparent field.
    private let photoSize = CGSize(width: 1600, height: 1000)
    private let block = CGRect(x: 600, y: 300, width: 400, height: 400)

    private func picture(transparentBackground: Bool) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(photoSize.width), height: Int(photoSize.height),
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if !transparentBackground {
            context.setFillColor(CGColor(srgbRed: 0.4, green: 0.7, blue: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: photoSize))
        }
        context.setFillColor(CGColor(srgbRed: 0.4, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(block)
        return try XCTUnwrap(context.makeImage())
    }

    private func render(_ scene: ScreenSaverScene, photo: CGImage, cutout: CGImage) throws -> CGImage {
        let renderer = ImageRenderer(content: SceneFrameView(scene: scene, date: Date(), time: 0, size: canvas,
                                                             background: SceneFrameBackground(current: photo),
                                                             assetImage: { $0 == "cutout.png" ? cutout : nil }))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }

    private func isBrown(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 70 && p.r < 140 && p.g < 90 && p.b < 60 }
    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 230 && p.g > 230 && p.b > 230 }
    private func isSky(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 220 && p.r < 140 }

    /// A solid white band across the middle: what the subject is tested
    /// against. Full-block glyphs leave no gaps to land in by accident.
    private var band: SceneLayer {
        var layer = SceneLayer.text("██████████████")
        layer.content = .text(TextLayer(segments: [.text("██████████████")], shadow: false))
        layer.size = 0.3
        return layer
    }

    private var scene: ScreenSaverScene {
        var scene = ScreenSaverScene()
        scene.background.source = .image(assetName: "photo.jpg")
        scene.background.treatment.scaleMode = .fill
        return scene
    }

    func testPinnedSubjectCoversLayersBelowAndShowsLayersAbove() throws {
        let photo = try picture(transparentBackground: false)
        let cutout = try picture(transparentBackground: true)
        var subject = SceneLayer.subject(imageAssetName: "cutout.png", sourceAssetName: "photo.jpg")
        subject.content = .subject(SubjectLayer(imageAssetName: "cutout.png", sourceAssetName: "photo.jpg", isPinned: true))
        // The 1600×1000 photo fills the 400×250 canvas at 1/4: the block is
        // x 150–250, y 75–175. Centre is inside it; (60, 125) is beside it.
        let centre = (x: 200, y: 125), beside = (x: 60, y: 125)

        var over = scene
        over.layers = [band, subject]
        let overImage = try render(over, photo: photo, cutout: cutout)
        XCTAssertTrue(isBrown(try pixel(overImage, x: centre.x, y: centre.y)), "subject above the band must cover it")
        XCTAssertTrue(isWhite(try pixel(overImage, x: beside.x, y: beside.y)), "the band shows through the cutout's transparency")

        var under = scene
        under.layers = [subject, band]
        let underImage = try render(under, photo: photo, cutout: cutout)
        XCTAssertTrue(isWhite(try pixel(underImage, x: centre.x, y: centre.y)), "band above the subject must cover it")

        var alone = scene
        alone.layers = [subject]
        let aloneImage = try render(alone, photo: photo, cutout: cutout)
        XCTAssertTrue(isBrown(try pixel(aloneImage, x: centre.x, y: centre.y)))
        XCTAssertTrue(isSky(try pixel(aloneImage, x: beside.x, y: beside.y)))
    }

    func testPinnedSubjectFollowsTheBackgroundZoomAndFocus() throws {
        let photo = try picture(transparentBackground: false)
        let cutout = try picture(transparentBackground: true)
        var zoomed = scene
        zoomed.background.treatment.zoom = 2
        zoomed.background.treatment.focus = ScenePoint(x: 0, y: 0)   // keep the top-left
        var pinned = SceneLayer.subject(imageAssetName: "cutout.png")
        pinned.content = .subject(SubjectLayer(imageAssetName: "cutout.png", isPinned: true))
        zoomed.layers = [band, pinned]
        let image = try render(zoomed, photo: photo, cutout: cutout)
        // At 2× keeping the top-left, the block spans x 300–500, y 150–350
        // on the canvas: (350, 200) is block, (200, 125) is now band.
        XCTAssertTrue(isBrown(try pixel(image, x: 350, y: 200)))
        XCTAssertTrue(isWhite(try pixel(image, x: 200, y: 125)))
    }

    func testUnpinnedSubjectIsAnOrdinaryLayer() throws {
        let photo = try picture(transparentBackground: false)
        let cutout = try picture(transparentBackground: true)
        var free = scene
        var subject = SceneLayer.subject(imageAssetName: "cutout.png")
        subject.content = .subject(SubjectLayer(imageAssetName: "cutout.png", isPinned: false))
        subject.size = 0.4                                   // 100pt tall → block is 40pt
        subject.position = ScenePoint(x: 0.1, y: 0.5)        // centred at (40, 125)
        free.layers = [subject]
        let image = try render(free, photo: photo, cutout: cutout)
        XCTAssertTrue(isBrown(try pixel(image, x: 40, y: 125)), "cutout drawn at its own position")
        XCTAssertTrue(isSky(try pixel(image, x: 100, y: 125)), "the cutout is only 40pt wide")
        // The photo behind still has its own block, of course.
        XCTAssertTrue(isBrown(try pixel(image, x: 200, y: 125)))
    }

    func testUnpinnedSubjectWithBoundsIsJustTheSubject() throws {
        let photo = try picture(transparentBackground: false)
        let cutout = try picture(transparentBackground: true)
        var free = scene
        var subject = SceneLayer.subject(imageAssetName: "cutout.png")
        // The block's own rect in the photo: x 600–1000 of 1600, y 300–700 of 1000.
        subject.content = .subject(SubjectLayer(imageAssetName: "cutout.png",
                                                bounds: SceneRect(x: 0.375, y: 0.3, width: 0.25, height: 0.4),
                                                isPinned: false))
        subject.size = 0.4                                   // the block itself is now 100pt tall
        subject.position = ScenePoint(x: 0.2, y: 0.5)        // centred at (80, 125): x 30–130, y 75–175
        free.layers = [subject]
        let image = try render(free, photo: photo, cutout: cutout)
        XCTAssertTrue(isBrown(try pixel(image, x: 40, y: 85)), "block fills its 100pt box")
        XCTAssertTrue(isBrown(try pixel(image, x: 120, y: 165)))
        XCTAssertTrue(isSky(try pixel(image, x: 20, y: 125)), "nothing outside the box")
    }
}
