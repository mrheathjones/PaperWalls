import XCTest

final class SceneCoverageTests: XCTestCase {
    /// 4×2 mask whose left half is opaque.
    private let leftHalf = SceneAlphaMask(width: 4, height: 2, opaque: [true, true, false, false,
                                                                       true, true, false, false])

    func testUnitSamplingRespectsBoundsAndOrigin() {
        XCTAssertTrue(leftHalf.isOpaque(atUnitX: 0.1, y: 0.1))
        XCTAssertTrue(leftHalf.isOpaque(atUnitX: 0.49, y: 0.9))
        XCTAssertFalse(leftHalf.isOpaque(atUnitX: 0.51, y: 0.5))
        XCTAssertFalse(leftHalf.isOpaque(atUnitX: -0.1, y: 0.5))
        XCTAssertFalse(leftHalf.isOpaque(atUnitX: 0.5, y: 1))
    }

    func testFractionCountsOpaqueOverlapOnly() {
        let maskRect = CGRect(x: 0, y: 0, width: 400, height: 200)
        // A rect spanning the whole mask: half covered.
        XCTAssertEqual(SceneCoverage.fraction(of: maskRect, coveredBy: leftHalf, drawnIn: maskRect), 0.5, accuracy: 0.02)
        // Entirely inside the opaque half.
        XCTAssertEqual(SceneCoverage.fraction(of: CGRect(x: 10, y: 10, width: 100, height: 100),
                                              coveredBy: leftHalf, drawnIn: maskRect), 1, accuracy: 0.001)
        // Entirely in the transparent half.
        XCTAssertEqual(SceneCoverage.fraction(of: CGRect(x: 250, y: 10, width: 100, height: 100),
                                              coveredBy: leftHalf, drawnIn: maskRect), 0)
        // Half outside the mask altogether, the inside half opaque.
        XCTAssertEqual(SceneCoverage.fraction(of: CGRect(x: -100, y: 0, width: 200, height: 200),
                                              coveredBy: leftHalf, drawnIn: maskRect), 0.5, accuracy: 0.02)
        XCTAssertEqual(SceneCoverage.fraction(of: CGRect(x: 500, y: 0, width: 10, height: 10),
                                              coveredBy: leftHalf, drawnIn: maskRect), 0)
    }

    func testMaskFromImageReadsAlphaTopDown() throws {
        // 40×20 image: top-left quadrant opaque, rest clear.
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 10, width: 20, height: 10))   // CG origin is bottom-left
        let mask = try XCTUnwrap(SceneAlphaMask(image: try XCTUnwrap(context.makeImage()), maxPixelSize: 40))
        XCTAssertEqual(mask.width, 40)
        XCTAssertEqual(mask.height, 20)
        XCTAssertTrue(mask.isOpaque(atUnitX: 0.25, y: 0.25), "top-left")
        XCTAssertFalse(mask.isOpaque(atUnitX: 0.25, y: 0.75), "bottom-left")
        XCTAssertFalse(mask.isOpaque(atUnitX: 0.75, y: 0.25), "top-right")

        let small = try XCTUnwrap(SceneAlphaMask(image: try XCTUnwrap(context.makeImage()), maxPixelSize: 8))
        XCTAssertEqual(small.width, 8)
        XCTAssertEqual(small.height, 4)
        XCTAssertTrue(small.isOpaque(atUnitX: 0.2, y: 0.2))
    }

    func testBackgroundGeometryMatchesTheFits() {
        let canvas = CGSize(width: 400, height: 250)
        let image = CGSize(width: 1600, height: 1000)   // same shape: fill == fit
        var treatment = SceneBackgroundTreatment()
        XCTAssertEqual(SceneBackgroundGeometry.imageRect(imageSize: image, canvas: canvas, treatment: treatment, displayScale: 2),
                       CGRect(origin: .zero, size: canvas))
        treatment.scaleMode = .fit
        XCTAssertEqual(SceneBackgroundGeometry.imageRect(imageSize: image, canvas: canvas, treatment: treatment, displayScale: 2),
                       CGRect(origin: .zero, size: canvas))

        // Fill at 2× keeping the top-left corner: the image is 800×500 at (0, 0).
        treatment.scaleMode = .fill
        treatment.zoom = 2
        treatment.focus = ScenePoint(x: 0, y: 0)
        XCTAssertEqual(SceneBackgroundGeometry.imageRect(imageSize: image, canvas: canvas, treatment: treatment, displayScale: 2),
                       CGRect(x: 0, y: 0, width: 800, height: 500))
        // …keeping the bottom-right corner: it ends at the canvas edge.
        treatment.focus = ScenePoint(x: 1, y: 1)
        XCTAssertEqual(SceneBackgroundGeometry.imageRect(imageSize: image, canvas: canvas, treatment: treatment, displayScale: 2),
                       CGRect(x: -400, y: -250, width: 800, height: 500))

        // A tall image fitted: letterboxed and centred.
        treatment = SceneBackgroundTreatment(scaleMode: .fit)
        XCTAssertEqual(SceneBackgroundGeometry.imageRect(imageSize: CGSize(width: 500, height: 1000), canvas: canvas,
                                                         treatment: treatment, displayScale: 2),
                       CGRect(x: 137.5, y: 0, width: 125, height: 250))
        // Stretch is the canvas; Center is pixel size over the display scale.
        treatment.scaleMode = .stretch
        XCTAssertEqual(SceneBackgroundGeometry.imageRect(imageSize: image, canvas: canvas, treatment: treatment, displayScale: 2),
                       CGRect(origin: .zero, size: canvas))
        treatment.scaleMode = .center
        XCTAssertEqual(SceneBackgroundGeometry.imageRect(imageSize: CGSize(width: 200, height: 100), canvas: canvas,
                                                         treatment: treatment, displayScale: 2),
                       CGRect(x: 150, y: 100, width: 100, height: 50))
    }

    func testSubjectRectPinnedAndFree() {
        let canvas = CGSize(width: 400, height: 250)
        let mask = SceneAlphaMask(width: 160, height: 100, opaque: [Bool](repeating: true, count: 16000))
        var layer = SceneLayer.subject(imageAssetName: "c.png",
                                       bounds: SceneRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        guard case .subject(var subject) = layer.content else { return XCTFail() }

        subject.isPinned = true
        let pinned = SceneCoverage.subjectRect(subject, layer: layer, mask: mask, treatment: SceneBackgroundTreatment(),
                                               canvas: canvas, displayScale: 2)
        XCTAssertEqual(pinned.rect, CGRect(origin: .zero, size: canvas))
        XCTAssertEqual(pinned.maskRect, pinned.rect)

        // Free: the 80×50 crop drawn 100pt tall (160 wide) centred at (200, 125);
        // the whole mask is twice that, offset so the crop lands there.
        subject.isPinned = false
        layer.size = 0.4
        layer.position = .center
        let free = SceneCoverage.subjectRect(subject, layer: layer, mask: mask, treatment: SceneBackgroundTreatment(),
                                             canvas: canvas, displayScale: 2)
        XCTAssertEqual(free.rect, CGRect(x: 120, y: 75, width: 160, height: 100))
        XCTAssertEqual(free.maskRect, CGRect(x: 40, y: -25, width: 320, height: 200))
    }
}
