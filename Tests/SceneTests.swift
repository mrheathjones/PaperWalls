import XCTest

// MARK: - Motion math (spec §10)

final class SceneMotionMathTests: XCTestCase {
    private let canvas = CGSize(width: 1000, height: 600)
    private let layerSize = CGSize(width: 200, height: 100)

    private func state(_ kind: SceneMotion.Kind,
                       speed: Double = 0.5,
                       intensity: Double = 0.5,
                       anchor: ScenePoint = .center,
                       time: TimeInterval) -> SceneLayerState {
        SceneMotionMath.state(motion: SceneMotion(kind: kind, speed: speed, intensity: intensity),
                              anchor: anchor, layerSize: layerSize, canvas: canvas, time: time)
    }

    func testTriangleWavePingPongs() {
        XCTAssertEqual(SceneMotionMath.triangleWave(distance: 0, range: 100).position, 0)
        XCTAssertEqual(SceneMotionMath.triangleWave(distance: 40, range: 100).position, 40)
        XCTAssertEqual(SceneMotionMath.triangleWave(distance: 100, range: 100).position, 100)
        XCTAssertEqual(SceneMotionMath.triangleWave(distance: 130, range: 100).position, 70)
        XCTAssertEqual(SceneMotionMath.triangleWave(distance: 200, range: 100).position, 0)
        XCTAssertEqual(SceneMotionMath.triangleWave(distance: 250, range: 100).position, 50)
    }

    func testTriangleWaveCountsEdgeHits() {
        XCTAssertEqual(SceneMotionMath.triangleWave(distance: 99, range: 100).bounces, 0)
        XCTAssertEqual(SceneMotionMath.triangleWave(distance: 100, range: 100).bounces, 1)
        XCTAssertEqual(SceneMotionMath.triangleWave(distance: 250, range: 100).bounces, 2)
    }

    func testTriangleWaveWithNoRoomStaysPut() {
        let wave = SceneMotionMath.triangleWave(distance: 500, range: 0)
        XCTAssertEqual(wave.position, 0)
        XCTAssertEqual(wave.bounces, 0)
    }

    func testStillRestsAtAnchor() {
        let result = state(.still, anchor: ScenePoint(x: 0.25, y: 0.75), time: 1234)
        XCTAssertEqual(result.center, CGPoint(x: 250, y: 450))
        XCTAssertEqual(result.scale, 1)
        XCTAssertEqual(result.opacity, 1)
    }

    func testBounceStartsAtAnchor() {
        let result = state(.bounce, time: 0)
        XCTAssertEqual(result.center.x, 500, accuracy: 0.001)
        XCTAssertEqual(result.center.y, 300, accuracy: 0.001)
        XCTAssertEqual(result.bounceCount, 0)
    }

    func testBounceNeverLeavesTheCanvas() {
        for step in 0..<2000 {
            let result = state(.bounce, speed: 1, time: Double(step) * 0.37)
            XCTAssertGreaterThanOrEqual(result.center.x, layerSize.width / 2 - 0.001)
            XCTAssertLessThanOrEqual(result.center.x, canvas.width - layerSize.width / 2 + 0.001)
            XCTAssertGreaterThanOrEqual(result.center.y, layerSize.height / 2 - 0.001)
            XCTAssertLessThanOrEqual(result.center.y, canvas.height - layerSize.height / 2 + 0.001)
        }
    }

    func testBounceAxesMoveAtDifferentSpeeds() {
        // Shortly after the start neither axis has reached an edge yet.
        let result = state(.bounce, speed: 0, time: 1)
        let dx = result.center.x - 500
        let dy = result.center.y - 300
        XCTAssertGreaterThan(dx, 0)
        XCTAssertEqual(dy / dx, SceneMotionMath.bounceAxisRatio, accuracy: 0.0001)
    }

    func testBounceCountOnlyGrows() {
        var previous = 0
        for step in 0..<500 {
            let count = state(.bounce, speed: 0.8, time: Double(step) * 0.5).bounceCount
            XCTAssertGreaterThanOrEqual(count, previous)
            previous = count
        }
        XCTAssertGreaterThan(previous, 0)
    }

    func testBounceIsAPureFunctionOfTime() {
        XCTAssertEqual(state(.bounce, time: 42.5), state(.bounce, time: 42.5))
    }

    func testLayerLargerThanCanvasDoesNotMove() {
        let result = SceneMotionMath.state(motion: SceneMotion(kind: .bounce, speed: 1),
                                           anchor: .center,
                                           layerSize: CGSize(width: 2000, height: 1200),
                                           canvas: canvas, time: 77)
        XCTAssertEqual(result.bounceCount, 0)
    }

    func testSpeedIsRelativeToCanvasHeight() {
        let small = SceneMotionMath.linearSpeed(0.5, canvasHeight: 600)
        let large = SceneMotionMath.linearSpeed(0.5, canvasHeight: 1200)
        XCTAssertEqual(large, small * 2, accuracy: 0.0001)
        XCTAssertGreaterThan(SceneMotionMath.linearSpeed(1, canvasHeight: 600),
                             SceneMotionMath.linearSpeed(0, canvasHeight: 600))
        XCTAssertGreaterThan(SceneMotionMath.linearSpeed(0, canvasHeight: 600), 0)
    }

    func testCyclicMotionsStayOnCanvas() {
        for kind in [SceneMotion.Kind.drift, .float, .orbit] {
            for step in 0..<500 {
                let result = state(kind, speed: 1, intensity: 1,
                                   anchor: ScenePoint(x: 0.95, y: 0.05), time: Double(step) * 0.73)
                XCTAssertGreaterThanOrEqual(result.center.x, layerSize.width / 2, "\(kind)")
                XCTAssertLessThanOrEqual(result.center.x, canvas.width - layerSize.width / 2, "\(kind)")
                XCTAssertGreaterThanOrEqual(result.center.y, layerSize.height / 2, "\(kind)")
                XCTAssertLessThanOrEqual(result.center.y, canvas.height - layerSize.height / 2, "\(kind)")
            }
        }
    }

    func testPulseScalesAroundOneWithoutMoving() {
        for step in 0..<200 {
            let result = state(.pulse, intensity: 1, time: Double(step) * 0.21)
            XCTAssertEqual(result.center, CGPoint(x: 500, y: 300))
            XCTAssertGreaterThan(result.scale, 0.7)
            XCTAssertLessThan(result.scale, 1.3)
        }
    }

    func testFadeStartsVisibleAndStaysInRange() {
        XCTAssertEqual(state(.fade, intensity: 1, time: 0).opacity, 1, accuracy: 0.0001)
        for step in 0..<200 {
            let opacity = state(.fade, intensity: 1, time: Double(step) * 0.21).opacity
            XCTAssertGreaterThanOrEqual(opacity, -0.0001)
            XCTAssertLessThanOrEqual(opacity, 1.0001)
        }
    }

    func testBouncePaletteWraps() {
        let count = SceneMotionMath.bouncePalette.count
        XCTAssertEqual(SceneMotionMath.bounceColorHex(bounceCount: 0),
                       SceneMotionMath.bounceColorHex(bounceCount: count))
        XCTAssertNotEqual(SceneMotionMath.bounceColorHex(bounceCount: 1),
                          SceneMotionMath.bounceColorHex(bounceCount: 2))
    }

    func testRotationPhaseAdvancesAndWraps() {
        let first = SceneMotionMath.rotationPhase(time: 10, interval: 60, count: 3)
        XCTAssertEqual(first.current, 0)
        XCTAssertEqual(first.next, 1)
        XCTAssertEqual(first.blend, 0)

        let last = SceneMotionMath.rotationPhase(time: 130, interval: 60, count: 3)
        XCTAssertEqual(last.current, 2)
        XCTAssertEqual(last.next, 0)
    }

    func testRotationPhaseCrossfadesAtEndOfInterval() {
        let mid = SceneMotionMath.rotationPhase(time: 59, interval: 60, count: 3, fadeDuration: 2)
        XCTAssertEqual(mid.current, 0)
        XCTAssertEqual(mid.blend, 0.5, accuracy: 0.0001)
        // The moment the fade completes, the faded-in image is `current`.
        let after = SceneMotionMath.rotationPhase(time: 60, interval: 60, count: 3, fadeDuration: 2)
        XCTAssertEqual(after.current, 1)
        XCTAssertEqual(after.blend, 0)
    }

    func testRotationPhaseHandlesEmptyPoolAndTinyInterval() {
        let empty = SceneMotionMath.rotationPhase(time: 100, interval: 60, count: 0)
        XCTAssertEqual(empty.current, 0)
        XCTAssertEqual(empty.blend, 0)
        // Intervals clamp to the minimum instead of spinning.
        let clamped = SceneMotionMath.rotationPhase(time: 4, interval: 0, count: 2)
        XCTAssertEqual(clamped.current, 0)
    }

    func testSlowZoomAlwaysCoversItsOwnPan() {
        for step in 0..<400 {
            let zoom = SceneMotionMath.slowZoom(time: Double(step) * 1.7)
            // Overscan per side must exceed the pan offset on that axis.
            let overscan = (zoom.scale - 1) / 2
            XCTAssertGreaterThanOrEqual(overscan, abs(zoom.offset.x))
            XCTAssertGreaterThanOrEqual(overscan, abs(zoom.offset.y))
        }
    }
}

// MARK: - Scene format (spec §10)

final class ScreenSaverSceneCodingTests: XCTestCase {
    private func decode(_ json: String) throws -> ScreenSaverScene {
        try JSONDecoder().decode(ScreenSaverScene.self, from: Data(json.utf8))
    }

    private func roundTrip(_ scene: ScreenSaverScene) throws -> ScreenSaverScene {
        try JSONDecoder().decode(ScreenSaverScene.self, from: JSONEncoder().encode(scene))
    }

    func testEveryPresetRoundTrips() throws {
        for preset in ScreenSaverPreset.allCases {
            // Each access builds a fresh scene (new layer IDs) — hold one.
            let scene = preset.scene
            XCTAssertEqual(try roundTrip(scene), scene, preset.displayName)
        }
    }

    func testEveryBackgroundSourceRoundTrips() throws {
        let sources: [SceneBackgroundSource] = [
            .currentDesktop,
            .wallpaper(id: "bundled-aurora-veil"),
            .rotatingPool(intervalSeconds: 45),
            .solid(colorHex: "1D2E3F"),
            .gradient(startHex: "112233", endHex: "445566", angleDegrees: 30),
        ]
        for source in sources {
            let scene = ScreenSaverScene(background: SceneBackground(source: source))
            XCTAssertEqual(try roundTrip(scene), scene)
        }
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let scene = try decode("{}")
        XCTAssertEqual(scene.background.source, .currentDesktop)
        XCTAssertEqual(scene.background.treatment, SceneBackgroundTreatment())
        XCTAssertTrue(scene.layers.isEmpty)
    }

    func testMissingLayerFieldsFallBackToDefaults() throws {
        let scene = try decode(#"{"layers": [{"content": {"kind": "clock"}}]}"#)
        let layer = try XCTUnwrap(scene.layers.first)
        XCTAssertEqual(layer.content, .clock(ClockLayer()))
        XCTAssertTrue(layer.isVisible)
        XCTAssertEqual(layer.position, .center)
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(layer.motion, SceneMotion())
    }

    func testOutOfRangeValuesAreClamped() throws {
        let scene = try decode("""
        {"background": {"treatment": {"blur": 7, "dim": -2}},
         "layers": [{"content": {"kind": "clock"}, "size": 40, "opacity": 3,
                     "position": {"x": -1, "y": 9},
                     "motion": {"kind": "bounce", "speed": 12}}]}
        """)
        XCTAssertEqual(scene.background.treatment.blur, 1)
        XCTAssertEqual(scene.background.treatment.dim, 0)
        let layer = try XCTUnwrap(scene.layers.first)
        XCTAssertEqual(layer.size, SceneLayer.sizeRange.upperBound)
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(layer.position, ScenePoint(x: 0, y: 1))
        XCTAssertEqual(layer.motion.speed, 1)
    }

    func testUnknownMotionKindHoldsStill() throws {
        let scene = try decode(#"{"layers": [{"content": {"kind": "clock"}, "motion": {"kind": "teleport", "speed": 0.9}}]}"#)
        XCTAssertEqual(scene.layers.first?.motion.kind, .still)
    }

    func testUnknownLayerKindIsPreservedNotDropped() throws {
        let json = #"{"layers": [{"content": {"kind": "shader", "name": "plasma", "uniforms": {"speed": 2, "tint": [1, 0.5, 0]}}}, {"content": {"kind": "clock"}}]}"#
        let scene = try decode(json)
        XCTAssertEqual(scene.layers.count, 2)
        guard case .unsupported(let kind, _) = scene.layers[0].content else {
            return XCTFail("expected an unsupported layer")
        }
        XCTAssertEqual(kind, "shader")

        // A load/save cycle in this version keeps the newer payload intact.
        let saved = try JSONEncoder().encode(scene)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        let content = try XCTUnwrap(layers[0]["content"] as? [String: Any])
        XCTAssertEqual(content["kind"] as? String, "shader")
        XCTAssertEqual(content["name"] as? String, "plasma")
        XCTAssertEqual((content["uniforms"] as? [String: Any])?["speed"] as? Double, 2)
    }

    func testUnknownBackgroundKindIsPreserved() throws {
        let scene = try decode(#"{"background": {"source": {"kind": "generated", "prompt": "misty forest", "seed": 7}}}"#)
        guard case .unsupported(let kind, _) = scene.background.source else {
            return XCTFail("expected an unsupported background")
        }
        XCTAssertEqual(kind, "generated")
        XCTAssertEqual(try roundTrip(scene), scene)
    }

    func testLayerContentEncodesFlatWithKind() throws {
        let scene = ScreenSaverScene(layers: [.text("Hello")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(scene)) as? [String: Any])
        let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        let content = try XCTUnwrap(layers[0]["content"] as? [String: Any])
        XCTAssertEqual(content["kind"] as? String, "text")
        XCTAssertNotNil(content["segments"])
    }

    func testUnknownTextTokenDecodesToEmptyText() throws {
        let scene = try decode(#"{"layers": [{"content": {"kind": "text", "segments": [{"text": "Hi "}, {"token": "weather"}, {"token": "date"}]}}]}"#)
        guard case .text(let text) = scene.layers.first?.content else {
            return XCTFail("expected a text layer")
        }
        XCTAssertEqual(text.segments, [.text("Hi "), .text(""), .token(.date)])
    }

    func testFontFamilyRoundTripsAndDefaultsToSystem() throws {
        var clock = SceneLayer.clock()
        clock.content = .clock(ClockLayer(font: SceneFont(design: .serif, weight: .bold, family: "Futura")))
        let scene = ScreenSaverScene(layers: [clock])
        XCTAssertEqual(try roundTrip(scene), scene)

        // Scenes saved before font families existed have no "family" key.
        let older = try decode(#"{"layers": [{"content": {"kind": "clock", "font": {"design": "serif", "weight": "bold"}}}]}"#)
        guard case .clock(let decoded) = older.layers.first?.content else {
            return XCTFail("expected a clock layer")
        }
        XCTAssertNil(decoded.font.family)
        XCTAssertEqual(decoded.font.design, .serif)
    }

    func testNewLayerDefaultsAreSensible() {
        for layer in [SceneLayer.clock(), .text(), .icon()] {
            XCTAssertTrue(layer.isVisible)
            XCTAssertTrue(SceneLayer.sizeRange.contains(layer.size))
            XCTAssertEqual(layer.opacity, 1)
            XCTAssertEqual(layer.motion.kind, .still)
        }
    }
}

// MARK: - Text, clock, color (spec §10)

final class SceneTextTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(hour: Int, minute: Int, second: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 2,
                                      hour: hour, minute: minute, second: second))!
    }

    func testTokensResolveFromHostValues() {
        let segments: [SceneTextSegment] = [.text("Contact "), .token(.companyName),
                                            .text(" — "), .token(.computerName)]
        let resolved = SceneTextResolver.resolve(
            segments,
            values: SceneTokenValues(computerName: "Lobby-iMac", companyName: "Acme"),
            date: Date())
        XCTAssertEqual(resolved, "Contact Acme — Lobby-iMac")
    }

    func testDateTokenUsesLocaleAndTimeZone() {
        let resolved = SceneTextResolver.resolve(
            [.token(.date)], values: SceneTokenValues(),
            date: date(hour: 12, minute: 0, second: 0),
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(resolved, "Friday, October 2")
    }

    func testTwelveHourClock() {
        XCTAssertEqual(SceneClockFormatter.timeString(for: date(hour: 0, minute: 5, second: 9),
                                                      uses24Hour: false, showsSeconds: false, calendar: utc),
                       "12:05")
        XCTAssertEqual(SceneClockFormatter.timeString(for: date(hour: 15, minute: 41, second: 7),
                                                      uses24Hour: false, showsSeconds: true, calendar: utc),
                       "3:41:07")
    }

    func testTwentyFourHourClock() {
        XCTAssertEqual(SceneClockFormatter.timeString(for: date(hour: 0, minute: 5, second: 9),
                                                      uses24Hour: true, showsSeconds: false, calendar: utc),
                       "00:05")
        XCTAssertEqual(SceneClockFormatter.timeString(for: date(hour: 15, minute: 41, second: 7),
                                                      uses24Hour: true, showsSeconds: true, calendar: utc),
                       "15:41:07")
    }

    func testHexColorParsing() {
        let coral = SceneColor.components(hex: "#FF8000")
        XCTAssertEqual(coral?.red ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(coral?.green ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(coral?.blue ?? 1, 0, accuracy: 0.001)
        XCTAssertNil(SceneColor.components(hex: "nope"))
        XCTAssertNil(SceneColor.components(hex: "FFF"))
    }
}
