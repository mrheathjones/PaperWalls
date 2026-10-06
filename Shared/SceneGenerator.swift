import Foundation

/// "Compose a screen saver with Claude": turns a plain-language brief into
/// a whole scene recipe — background, layers, motion — through the
/// Anthropic Messages API, asking for a JSON reply in a fixed schema.
/// Claude writes the recipe; nothing it says becomes a `ScreenSaverScene`
/// until `SceneComposition` has checked every value against the format
/// rules (spec §10). Claude never makes pictures: a composition can only
/// *describe* a background image (`imagePrompt`), which the image provider
/// the user chose then generates. Pure: builds the request, reads the reply.
struct SceneGenerator: Equatable {
    static let endpoint = PromptImprover.endpoint
    static let host = PromptImprover.host
    /// Shares the Improve feature's Claude key and model preference.
    static let keychainAccount = PromptImprover.keychainAccount
    static let defaultModel = PromptImprover.defaultModel
    static let apiVersion = PromptImprover.apiVersion
    static let fallbackBeta = PromptImprover.fallbackBeta

    /// What the prompt tells Claude about this Mac and this request.
    struct Context: Equatable {
        /// The company name from Settings, if any (so the `{companyName}`
        /// placeholder is offered only when it will show something).
        var companyName: String = ""
        /// True when an image provider can turn `imagePrompt` into a real
        /// background; otherwise generated backgrounds aren't offered.
        var canGenerateImage: Bool = false
    }

    var model: String = SceneGenerator.defaultModel

    /// Reads the live preference layers (the same model key as Improve).
    static func current() -> SceneGenerator {
        SceneGenerator(model: PromptImprover.current().model)
    }

    /// Models that take `output_config.effort` and server-side fallbacks.
    var usesCurrentGenerationOptions: Bool {
        PromptImprover(model: model).usesCurrentGenerationOptions
    }

    static let systemPrompt = """
    You design screen savers for Macs. The user describes the screen saver they want; \
    you reply with one scene recipe in the required JSON shape and nothing else.

    A scene is one background with layers drawn on top of it. The screen is a wide \
    desktop display (about 16:10). Everything is relative so it looks right on any screen:
    - x and y place a layer's CENTER: (0, 0) is the top-left corner, (1, 1) the bottom-right, \
    (0.5, 0.5) the middle. Keep layers between 0.1 and 0.9 so they never touch the edges.
    - size is the layer's height as a fraction of the screen height: a big clock 0.12–0.2, \
    a headline 0.05–0.08, a caption 0.025–0.04, an icon 0.08–0.2.
    - opacity is 0–1 (1 = solid). Use 1 for the main element, 0.8–0.9 for supporting lines.

    Backgrounds: "currentDesktop" is whatever the Mac's desktop picture is (add blur 0.2–0.6 and \
    dim 0.3–0.6 so text stays readable); "solid" takes colorHex; "gradient" takes startHex, \
    endHex and angleDegrees (0 = left to right, 90 = bottom to top); "rotatingPool" crossfades \
    through the user's wallpapers (also blur and dim it)\(Context.generatedImageClause). \
    Colors are six-digit hex without "#". blur and dim are 0–1. slowZoom adds a slow Ken Burns drift.

    Layers, each with a kind:
    - "clock": the live time. Options uses24Hour, showsSeconds, showsDate (a smaller date line \
    under the time, which makes the layer about a third taller — leave room below it).
    - "text": a line of text in `text`. These placeholders are replaced live: {date} (e.g. \
    "Friday, October 2"), {computerName} (this Mac's name), {companyName} (the organization's name). \
    Keep lines short; use one text layer per line.
    - "icon": an SF Symbol in symbolName. Use only common symbols, e.g. sparkles, clock, \
    moon.stars, sun.max, star, heart, bolt, leaf, cloud, snowflake, flame, drop, lock, \
    wifi, globe, airplane, bell, flag, lifepreserver, hand.wave, cup.and.saucer, music.note, \
    laptopcomputer, building.2, person.crop.circle, checkmark.circle, exclamationmark.triangle.
    Text and icon colors are colorHex (light colors on dark backgrounds); shadow adds a soft drop \
    shadow for legibility. fontDesign is system, rounded, serif or monospaced; fontWeight is \
    ultraLight, thin, light, regular, medium, semibold, bold, heavy or black.

    Motion per layer: "still", "bounce" (DVD-logo style, changesColorOnBounce steps through \
    colors on each edge hit), "drift" (slow wander), "float" (gentle up-and-down), "pulse" \
    (breathing scale), "fade" (in and out), "orbit" (small circle). speed and intensity are 0–1; \
    0.1–0.4 is calm, above 0.6 is lively. Screen savers run for hours: prefer still or slow \
    motion, and never park a bright element in one spot — give it at least a gentle drift. \
    Use at most 6 layers, and don't let them overlap: space stacked lines about 0.08 apart.

    name: a short title for the screen saver (two to four words).
    """

    /// The reply shape (JSON outputs, `output_config.format`). Optional
    /// fields are left out of `required`; the decoder fills defaults.
    static let replySchema: [String: Any] = {
        func string() -> [String: Any] { ["type": "string"] }
        func number() -> [String: Any] { ["type": "number"] }
        func bool() -> [String: Any] { ["type": "boolean"] }
        func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["name", "background", "layers"],
            "properties": [
                "name": string(),
                "background": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["kind"],
                    "properties": [
                        "kind": choice(SceneComposition.Background.Kind.allCases.map(\.rawValue)),
                        "colorHex": string(),
                        "startHex": string(),
                        "endHex": string(),
                        "angleDegrees": number(),
                        "imagePrompt": string(),
                        "blur": number(),
                        "dim": number(),
                        "slowZoom": bool(),
                    ],
                ],
                "layers": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["kind", "x", "y", "size"],
                        "properties": [
                            "kind": choice(SceneComposition.Layer.Kind.allCases.map(\.rawValue)),
                            "x": number(),
                            "y": number(),
                            "size": number(),
                            "opacity": number(),
                            "text": string(),
                            "symbolName": string(),
                            "colorHex": string(),
                            "shadow": bool(),
                            "fontDesign": choice(SceneFont.Design.allCases.map(\.rawValue)),
                            "fontWeight": choice(SceneFont.Weight.allCases.map(\.rawValue)),
                            "uses24Hour": bool(),
                            "showsSeconds": bool(),
                            "showsDate": bool(),
                            "motion": choice(SceneMotion.Kind.allCases.map(\.rawValue)),
                            "speed": number(),
                            "intensity": number(),
                            "changesColorOnBounce": bool(),
                        ],
                    ],
                ],
            ],
        ]
    }()

    func request(brief: String, context: Context = Context(), apiKey: String) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ImageEndpointError.missingAPIKey("Claude") }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": Self.systemPrompt.replacingOccurrences(of: Context.generatedImageClause,
                                                             with: context.generatedImageClause),
            "messages": [["role": "user", "content": context.userMessage(brief: brief)]],
        ]
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": Self.replySchema]]
        if usesCurrentGenerationOptions {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
            outputConfig["effort"] = "low"
        }
        body["output_config"] = outputConfig
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The composition in a Messages reply. With JSON outputs the text
    /// block is the JSON itself; a fenced or padded reply is tolerated.
    static func composition(fromResponse data: Data) throws -> SceneComposition {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageEndpointError.badPayload
        }
        if object["stop_reason"] as? String == "refusal" {
            throw ImageEndpointError.refused
        }
        guard let content = object["content"] as? [[String: Any]] else { throw ImageEndpointError.badPayload }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        guard let json = Self.jsonObject(in: text) else { throw ImageEndpointError.badPayload }
        do {
            return try JSONDecoder().decode(SceneComposition.self, from: json)
        } catch {
            throw ImageEndpointError.badPayload
        }
    }

    /// The first `{ … }` object in a reply, as bytes — skipping any prose
    /// or ``` fences around it.
    static func jsonObject(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return Data(text[start...end].utf8)
    }
}

extension SceneGenerator.Context {
    /// Placeholder in the system prompt for the generated-image option.
    static let generatedImageClause = "{GENERATED_IMAGE_CLAUSE}"

    var generatedImageClause: String {
        guard canGenerateImage else { return "" }
        return """
        ; "generatedImage" describes a picture to generate in imagePrompt (subject, setting, lighting, \
        palette, mood, style — a wide, uncluttered desktop background in under 60 words), which the \
        user's image service then makes — choose it when the description wants a picture
        """
    }

    /// The user turn: the brief, plus what's known about this Mac.
    func userMessage(brief: String) -> String {
        var lines = ["Screen saver request: \(brief)"]
        let company = companyName.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(company.isEmpty
            ? "No company name is set on this Mac, so avoid the {companyName} placeholder."
            : "The company name on this Mac is “\(company)” (available as {companyName}).")
        return lines.joined(separator: "\n")
    }
}

// MARK: - The reply

/// Claude's scene recipe, in the friendlier shape the schema asks for.
/// Converting it to a `ScreenSaverScene` applies the format rules: values
/// are clamped, colors checked, unknown symbols and placeholders replaced,
/// and backgrounds Claude can't pick (library wallpapers, asset names)
/// aren't offered at all.
struct SceneComposition: Codable, Equatable {
    struct Background: Codable, Equatable {
        enum Kind: String, Codable, CaseIterable {
            case currentDesktop
            case solid
            case gradient
            case rotatingPool
            case generatedImage
        }

        var kind: Kind
        var colorHex: String?
        var startHex: String?
        var endHex: String?
        var angleDegrees: Double?
        var imagePrompt: String?
        var blur: Double?
        var dim: Double?
        var slowZoom: Bool?
    }

    struct Layer: Codable, Equatable {
        enum Kind: String, Codable, CaseIterable {
            case clock
            case text
            case icon
        }

        var kind: Kind
        var x: Double
        var y: Double
        var size: Double
        var opacity: Double?
        var text: String?
        var symbolName: String?
        var colorHex: String?
        var shadow: Bool?
        var fontDesign: SceneFont.Design?
        var fontWeight: SceneFont.Weight?
        var uses24Hour: Bool?
        var showsSeconds: Bool?
        var showsDate: Bool?
        var motion: SceneMotion.Kind?
        var speed: Double?
        var intensity: Double?
        var changesColorOnBounce: Bool?
    }

    var name: String
    var background: Background
    var layers: [Layer]

    /// At most this many layers are kept (the prompt asks for six).
    static let maxLayers = 8
    static let fallbackSymbol = "sparkles"
    static let fallbackBackgroundHex = "0B0B0F"
    static let fallbackForegroundHex = "FFFFFF"

    /// The description of a picture to generate, when the recipe asked
    /// for one (and said what it should be).
    var imagePrompt: String? {
        guard background.kind == .generatedImage else { return nil }
        let prompt = (background.imagePrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    /// The composition as a scene. `symbolExists` says whether an SF Symbol
    /// name is real on this Mac (unknown ones become `fallbackSymbol`).
    /// A generated-image background becomes a dark gradient here; the
    /// caller swaps in the picture once the image provider has made it.
    func scene(symbolExists: (String) -> Bool) -> ScreenSaverScene {
        var scene = ScreenSaverScene()
        scene.background = sceneBackground
        scene.layers = layers.prefix(Self.maxLayers).map { $0.sceneLayer(symbolExists: symbolExists) }
        return scene
    }

    /// A name that can be saved: Claude's, trimmed, or a stand-in.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Composed Screen Saver" : String(trimmed.prefix(60))
    }

    private var sceneBackground: SceneBackground {
        var treatment = SceneBackgroundTreatment()
        treatment.blur = (background.blur ?? 0).clampedToUnit
        treatment.dim = (background.dim ?? 0).clampedToUnit
        treatment.slowZoom = background.slowZoom ?? false
        let source: SceneBackgroundSource
        switch background.kind {
        case .currentDesktop:
            source = .currentDesktop
        case .rotatingPool:
            source = .rotatingPool(intervalSeconds: SceneBackgroundSource.defaultRotationInterval)
        case .solid:
            source = .solid(colorHex: Self.hex(background.colorHex, fallback: Self.fallbackBackgroundHex))
        case .gradient:
            source = .gradient(startHex: Self.hex(background.startHex, fallback: "2B1B4A"),
                               endHex: Self.hex(background.endHex, fallback: Self.fallbackBackgroundHex),
                               angleDegrees: Self.angle(background.angleDegrees))
        case .generatedImage:
            // Placeholder until (unless) the picture arrives.
            source = .gradient(startHex: Self.hex(background.startHex, fallback: "1D2E3F"),
                               endHex: Self.hex(background.endHex, fallback: Self.fallbackBackgroundHex),
                               angleDegrees: Self.angle(background.angleDegrees))
        }
        return SceneBackground(source: source, treatment: treatment)
    }

    /// "RRGGBB" / "#RRGGBB" (any case) normalized, else the fallback.
    static func hex(_ value: String?, fallback: String) -> String {
        guard let value, SceneColor.components(hex: value) != nil else { return fallback }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
    }

    private static func angle(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 90 }
        return value.truncatingRemainder(dividingBy: 360)
    }
}

extension SceneComposition.Layer {
    /// Placeholders the prompt offers, in the form Claude writes them.
    static let placeholders: [(String, SceneTextToken)] = [
        ("{date}", .date), ("{computerName}", .computerName), ("{companyName}", .companyName),
    ]

    func sceneLayer(symbolExists: (String) -> Bool) -> SceneLayer {
        let font = SceneFont(design: fontDesign ?? .rounded, weight: fontWeight ?? .semibold)
        let color = SceneComposition.hex(colorHex, fallback: SceneComposition.fallbackForegroundHex)
        let content: SceneLayerContent
        switch kind {
        case .clock:
            content = .clock(ClockLayer(uses24Hour: uses24Hour ?? false,
                                        showsSeconds: showsSeconds ?? false,
                                        showsDate: showsDate ?? false,
                                        font: font, colorHex: color, shadow: shadow ?? true))
        case .text:
            content = .text(TextLayer(segments: Self.segments(from: text ?? ""),
                                      font: font, colorHex: color, shadow: shadow ?? true))
        case .icon:
            let symbol = (symbolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            content = .icon(IconLayer(symbolName: symbol.isEmpty || !symbolExists(symbol)
                                          ? SceneComposition.fallbackSymbol : symbol,
                                      colorHex: color, shadow: shadow ?? true))
        }
        var layer = SceneLayer(content: content)
        layer.position = ScenePoint(x: x.clampedToUnit, y: y.clampedToUnit)
        layer.size = min(max(size, SceneLayer.sizeRange.lowerBound), SceneLayer.sizeRange.upperBound)
        layer.opacity = (opacity ?? 1).clampedToUnit
        layer.motion = SceneMotion(kind: motion ?? .still,
                                   speed: (speed ?? 0.35).clampedToUnit,
                                   intensity: (intensity ?? 0.5).clampedToUnit,
                                   changesColorOnBounce: changesColorOnBounce ?? false)
        return layer
    }

    /// "{date} · {companyName}" → text and token segments, normalized.
    static func segments(from text: String) -> [SceneTextSegment] {
        var result: [SceneTextSegment] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            // The earliest placeholder wins; everything before it is text.
            let next = placeholders
                .compactMap { marker, token in remaining.range(of: marker).map { ($0, token) } }
                .min { $0.0.lowerBound < $1.0.lowerBound }
            guard let next else {
                result.append(.text(String(remaining)))
                break
            }
            let (range, token) = next
            result.append(.text(String(remaining[remaining.startIndex..<range.lowerBound])))
            result.append(.token(token))
            remaining = remaining[range.upperBound...]
        }
        return result.normalized
    }
}
