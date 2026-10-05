import XCTest

// MARK: - Compose with Claude (Studio › ScreenSaver)

final class SceneGeneratorTests: XCTestCase {
    private func body(of request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testRequestAsksForJSONInTheSceneSchema() throws {
        let request = try SceneGenerator().request(brief: "a calm clock", apiKey: "sk-ant-test")
        XCTAssertEqual(request.url, SceneGenerator.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = try body(of: request)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "low")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema["required"] as? [String], ["name", "background", "layers"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(try XCTUnwrap(messages.first?["content"] as? String).contains("a calm clock"))
    }

    func testEveryObjectInTheSchemaForbidsExtraProperties() throws {
        func check(_ node: Any, path: String) {
            guard let object = node as? [String: Any] else { return }
            if object["type"] as? String == "object" {
                XCTAssertEqual(object["additionalProperties"] as? Bool, false, path)
            }
            for (key, value) in object {
                check(value, path: "\(path).\(key)")
            }
        }
        check(SceneGenerator.replySchema, path: "schema")
        // The enums are the model's own vocabularies, so nothing drifts.
        let layer = try XCTUnwrap(((SceneGenerator.replySchema["properties"] as? [String: Any])?["layers"] as? [String: Any])?["items"] as? [String: Any])
        let properties = try XCTUnwrap(layer["properties"] as? [String: Any])
        XCTAssertEqual((properties["motion"] as? [String: Any])?["enum"] as? [String], SceneMotion.Kind.allCases.map(\.rawValue))
        XCTAssertEqual((properties["fontWeight"] as? [String: Any])?["enum"] as? [String], SceneFont.Weight.allCases.map(\.rawValue))
    }

    func testOlderModelsSkipTheNewOptionsButKeepTheSchema() throws {
        let request = try SceneGenerator(model: "claude-haiku-4-5").request(brief: "x", apiKey: "k")
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
        let body = try body(of: request)
        XCTAssertNil(body["fallbacks"])
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertNil(output["effort"])
        XCTAssertNotNil(output["format"])
    }

    func testContextShapesThePrompt() throws {
        let plain = try body(of: try SceneGenerator().request(brief: "x", apiKey: "k"))
        XCTAssertFalse(try XCTUnwrap(plain["system"] as? String).contains("generatedImage"),
                       "no image service → generated backgrounds aren't offered")
        XCTAssertTrue(try XCTUnwrap((plain["messages"] as? [[String: Any]])?.first?["content"] as? String)
            .contains("No company name"))

        let context = SceneGenerator.Context(companyName: " Acme Corp ", canGenerateImage: true)
        let rich = try body(of: try SceneGenerator().request(brief: "x", context: context, apiKey: "k"))
        let system = try XCTUnwrap(rich["system"] as? String)
        XCTAssertTrue(system.contains("\"generatedImage\""))
        XCTAssertFalse(system.contains(SceneGenerator.Context.generatedImageClause), "placeholder is filled in")
        XCTAssertTrue(try XCTUnwrap((rich["messages"] as? [[String: Any]])?.first?["content"] as? String)
            .contains("“Acme Corp”"))
    }

    func testMissingKeyIsAnError() {
        XCTAssertThrowsError(try SceneGenerator().request(brief: "x", apiKey: "")) {
            XCTAssertEqual($0 as? ImageEndpointError, .missingAPIKey("Claude"))
        }
    }

    // MARK: Reply parsing

    /// A reply as Claude might write it: fenced, with the JSON on one line.
    private let reply: String = {
        let scene = """
        {"name": "Night Clock", "background": {"kind": "gradient", "startHex": "#1a2b3c", "endHex": "000000", "angleDegrees": 450, "blur": 2},
         "layers": [{"kind": "clock", "x": 0.5, "y": 0.4, "size": 0.9, "showsDate": true, "fontWeight": "light", "motion": "drift", "speed": 0.1},
                    {"kind": "text", "x": 1.5, "y": -1, "size": 0.04, "text": "{companyName} · {date}", "colorHex": "not-a-color", "opacity": 0.8},
                    {"kind": "icon", "x": 0.5, "y": 0.7, "size": 0.1, "symbolName": "made.up.symbol"}]}
        """
        let text = "```json\n" + scene.replacingOccurrences(of: "\n", with: " ") + "\n```"
        let envelope: [String: Any] = [
            "stop_reason": "end_turn",
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    }()

    func testReplyIsDecodedThroughCodeFences() throws {
        let composition = try SceneGenerator.composition(fromResponse: Data(reply.utf8))
        XCTAssertEqual(composition.name, "Night Clock")
        XCTAssertEqual(composition.background.kind, .gradient)
        XCTAssertEqual(composition.layers.count, 3)
        XCTAssertEqual(composition.layers[0].fontWeight, .light)
        XCTAssertNil(composition.imagePrompt)
    }

    func testRefusalsAndBadRepliesAreErrors() {
        XCTAssertThrowsError(try SceneGenerator.composition(fromResponse: Data("{\"stop_reason\": \"refusal\", \"content\": []}".utf8))) {
            XCTAssertEqual($0 as? ImageEndpointError, .refused)
        }
        XCTAssertThrowsError(try SceneGenerator.composition(fromResponse: Data("{\"content\": [{\"type\": \"text\", \"text\": \"no json here\"}]}".utf8))) {
            XCTAssertEqual($0 as? ImageEndpointError, .badPayload)
        }
        XCTAssertThrowsError(try SceneGenerator.composition(fromResponse: Data("{\"content\": [{\"type\": \"text\", \"text\": \"{\\\"name\\\": 1}\"}]}".utf8))) {
            XCTAssertEqual($0 as? ImageEndpointError, .badPayload)
        }
        XCTAssertThrowsError(try SceneGenerator.composition(fromResponse: Data("not json".utf8)))
    }

    // MARK: Composition → scene

    func testSceneAppliesTheFormatRules() throws {
        let composition = try SceneGenerator.composition(fromResponse: Data(reply.utf8))
        let scene = composition.scene { $0 == "sparkles" || $0 == "clock" }

        XCTAssertEqual(scene.background.source, .gradient(startHex: "1A2B3C", endHex: "000000", angleDegrees: 90),
                       "hex is normalized and the angle wrapped")
        XCTAssertEqual(scene.background.treatment.blur, 1, "clamped to the unit range")

        XCTAssertEqual(scene.layers.count, 3)
        let clock = scene.layers[0]
        XCTAssertEqual(clock.size, SceneLayer.sizeRange.upperBound, "size clamped")
        XCTAssertEqual(clock.motion, SceneMotion(kind: .drift, speed: 0.1, intensity: 0.5))
        guard case .clock(let clockLayer) = clock.content else { return XCTFail("clock expected") }
        XCTAssertTrue(clockLayer.showsDate)
        XCTAssertEqual(clockLayer.font, SceneFont(design: .rounded, weight: .light))

        let text = scene.layers[1]
        XCTAssertEqual(text.position, ScenePoint(x: 1, y: 0))
        XCTAssertEqual(text.opacity, 0.8)
        guard case .text(let textLayer) = text.content else { return XCTFail("text expected") }
        XCTAssertEqual(textLayer.segments, [.token(.companyName), .text(" · "), .token(.date)])
        XCTAssertEqual(textLayer.colorHex, SceneComposition.fallbackForegroundHex, "an unparseable color falls back")

        guard case .icon(let icon) = scene.layers[2].content else { return XCTFail("icon expected") }
        XCTAssertEqual(icon.symbolName, SceneComposition.fallbackSymbol, "an unknown symbol falls back")

        XCTAssertEqual(composition.displayName, "Night Clock")
        // Round-trips through the stored format like any scene.
        let data = try ScreenSaverSceneStore.encoder.encode(scene)
        XCTAssertEqual(try ScreenSaverSceneStore.decoder.decode(ScreenSaverScene.self, from: data), scene)
    }

    func testKnownSymbolsAndPlainTextSurvive() {
        let layer = SceneComposition.Layer(kind: .icon, x: 0.2, y: 0.2, size: 0.1, symbolName: " moon.stars ", colorHex: "ffcc00")
        guard case .icon(let icon) = layer.sceneLayer(symbolExists: { $0 == "moon.stars" }).content else { return XCTFail() }
        XCTAssertEqual(icon.symbolName, "moon.stars")
        XCTAssertEqual(icon.colorHex, "FFCC00")

        XCTAssertEqual(SceneComposition.Layer.segments(from: "Be right back"), [.text("Be right back")])
        XCTAssertEqual(SceneComposition.Layer.segments(from: "{computerName}"), [.token(.computerName)])
        XCTAssertEqual(SceneComposition.Layer.segments(from: "Hi {unknown} there"), [.text("Hi {unknown} there")])
        XCTAssertEqual(SceneComposition.Layer.segments(from: ""), [])
    }

    func testGeneratedImageBackgroundsWaitForThePicture() {
        var composition = SceneComposition(
            name: "  ",
            background: SceneComposition.Background(kind: .generatedImage, imagePrompt: "  soft blue mountains at dawn "),
            layers: [])
        XCTAssertEqual(composition.imagePrompt, "soft blue mountains at dawn")
        XCTAssertEqual(composition.displayName, "Composed Screen Saver")
        guard case .gradient = composition.scene(symbolExists: { _ in true }).background.source else {
            return XCTFail("a gradient stands in until the picture arrives")
        }

        composition.background.imagePrompt = ""
        XCTAssertNil(composition.imagePrompt, "no description → nothing to generate")
        composition.background = SceneComposition.Background(kind: .solid, imagePrompt: "ignored")
        XCTAssertNil(composition.imagePrompt)
        XCTAssertEqual(composition.scene(symbolExists: { _ in true }).background.source,
                       .solid(colorHex: SceneComposition.fallbackBackgroundHex))
    }

    func testLayerCountIsCapped() {
        let layer = SceneComposition.Layer(kind: .text, x: 0.5, y: 0.5, size: 0.05, text: "x")
        let composition = SceneComposition(name: "Many", background: SceneComposition.Background(kind: .currentDesktop),
                                           layers: Array(repeating: layer, count: 20))
        XCTAssertEqual(composition.scene(symbolExists: { _ in true }).layers.count, SceneComposition.maxLayers)
    }

    func testJSONObjectExtraction() {
        XCTAssertEqual(SceneGenerator.jsonObject(in: "Here: {\"a\": {\"b\": 1}} done"), Data("{\"a\": {\"b\": 1}}".utf8))
        XCTAssertNil(SceneGenerator.jsonObject(in: "nothing"))
        XCTAssertNil(SceneGenerator.jsonObject(in: "} {"))
    }

    func testSceneComposerFollowsTheMasterSwitch() {
        XCTAssertFalse(AIGenerationPolicy(enabled: false, sceneComposer: true).offersSceneComposition)
        XCTAssertFalse(AIGenerationPolicy(enabled: true).offersSceneComposition)
        XCTAssertTrue(AIGenerationPolicy(enabled: true, sceneComposer: true).offersSceneComposition)
        XCTAssertFalse(AIGenerationPolicy(enabled: true, sceneComposer: true).offersGeneration,
                       "composing alone offers no image generation")
        XCTAssertTrue(AIGenerationPolicy(enabled: true, sceneComposer: true).usesClaude)
        XCTAssertTrue(AIGenerationPolicy(enabled: true, promptImprover: true).usesClaude)
        XCTAssertFalse(AIGenerationPolicy(enabled: true).usesClaude)
    }
}
