import Foundation

/// A screen saver "recipe" (spec §10): one background plus layers drawn in
/// order. Users never see or hand-edit this — Studio's controls bind
/// straight to it, and the same value drives the Studio preview, library
/// thumbnails, the fullscreen preview, and the real .saver.
///
/// Format rules (spec §10):
///   * Speeds, sizes and positions are RELATIVE (0–1, or a fraction of the
///     screen height) — the renderer converts to points at draw time, so a
///     scene looks right on any display.
///   * Decoding is lenient: a missing or unrecognized field falls back to
///     its default instead of failing the whole scene.
///   * Background sources and layer contents carry a `kind` discriminator.
///     An unknown kind (written by a newer version — e.g. a future
///     `generated` background or `shader` layer) is kept verbatim and
///     skipped at render time, never dropped.
struct ScreenSaverScene: Codable, Equatable {
    /// Bumped when the stored shape changes; the scene store's migration
    /// hook upgrades older files before decoding.
    static let currentSchemaVersion = 1

    var background = SceneBackground()
    var layers: [SceneLayer] = []
}

extension ScreenSaverScene {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        background = container.sceneValue(.background, default: SceneBackground())
        layers = container.sceneValue(.layers, default: [])
    }
}

// MARK: - Background

struct SceneBackground: Codable, Equatable {
    var source: SceneBackgroundSource = .currentDesktop
    var treatment = SceneBackgroundTreatment()
}

extension SceneBackground {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = container.sceneValue(.source, default: .currentDesktop)
        treatment = container.sceneValue(.treatment, default: SceneBackgroundTreatment())
    }
}

/// Where the background comes from. `currentDesktop` (whatever the desktop
/// picture is right now) is the default; the others are explicit choices.
enum SceneBackgroundSource: Equatable {
    case currentDesktop
    /// A specific library wallpaper (`CuratedWallpaper.id`).
    case wallpaper(id: String)
    /// Crossfades through the resolved rotation pool (spec §4 rules apply).
    case rotatingPool(intervalSeconds: Double)
    case solid(colorHex: String)
    case gradient(startHex: String, endHex: String, angleDegrees: Double)
    /// An image imported into the Studio asset store (the same store icon
    /// images use — see `SceneResources.assetURL`).
    case image(assetName: String)
    /// A kind this version doesn't know — preserved as-is, drawn as black.
    case unsupported(kind: String, payload: SceneJSONValue)

    static let defaultRotationInterval: Double = 60
}

extension SceneBackgroundSource: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SceneCodingKey.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "currentDesktop":
            self = .currentDesktop
        case "wallpaper":
            self = .wallpaper(id: try container.decode(String.self, forKey: "id"))
        case "rotatingPool":
            self = .rotatingPool(intervalSeconds: container.sceneValue(
                "intervalSeconds", default: Self.defaultRotationInterval))
        case "solid":
            self = .solid(colorHex: container.sceneValue("colorHex", default: "000000"))
        case "gradient":
            self = .gradient(startHex: container.sceneValue("startHex", default: "1D2E3F"),
                             endHex: container.sceneValue("endHex", default: "000000"),
                             angleDegrees: container.sceneValue("angleDegrees", default: 90))
        case "image":
            self = .image(assetName: container.sceneValue("assetName", default: ""))
        default:
            self = .unsupported(kind: kind, payload: try SceneJSONValue(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SceneCodingKey.self)
        switch self {
        case .currentDesktop:
            try container.encode("currentDesktop", forKey: .kind)
        case .wallpaper(let id):
            try container.encode("wallpaper", forKey: .kind)
            try container.encode(id, forKey: "id")
        case .rotatingPool(let intervalSeconds):
            try container.encode("rotatingPool", forKey: .kind)
            try container.encode(intervalSeconds, forKey: "intervalSeconds")
        case .solid(let colorHex):
            try container.encode("solid", forKey: .kind)
            try container.encode(colorHex, forKey: "colorHex")
        case .gradient(let startHex, let endHex, let angleDegrees):
            try container.encode("gradient", forKey: .kind)
            try container.encode(startHex, forKey: "startHex")
            try container.encode(endHex, forKey: "endHex")
            try container.encode(angleDegrees, forKey: "angleDegrees")
        case .image(let assetName):
            try container.encode("image", forKey: .kind)
            try container.encode(assetName, forKey: "assetName")
        case .unsupported(_, let payload):
            try payload.encode(to: encoder)
        }
    }
}

enum SceneScaleMode: String, Codable, CaseIterable, Identifiable {
    case fill
    case fit
    /// The whole image, with a blurred, enlarged copy of itself filling
    /// the rest of the canvas — no crop, no bars (for generated images,
    /// which are rarely the display's shape).
    case fitBlur
    case stretch
    case center

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .fitBlur: return "Fit + Blur"
        case .stretch: return "Stretch"
        case .center: return "Center"
        }
    }
}

/// How the background image is presented. `blur` and `dim` are 0–1.
struct SceneBackgroundTreatment: Codable, Equatable {
    var scaleMode: SceneScaleMode = .fill
    var blur: Double = 0
    var dim: Double = 0
    /// Slow zoom/pan ("Ken Burns").
    var slowZoom: Bool = false
}

extension SceneBackgroundTreatment {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scaleMode = container.sceneValue(.scaleMode, default: .fill)
        blur = container.sceneValue(.blur, default: 0).clampedToUnit
        dim = container.sceneValue(.dim, default: 0).clampedToUnit
        slowZoom = container.sceneValue(.slowZoom, default: false)
    }
}

// MARK: - Layers

/// Unit-space point: (0, 0) is the top-left of the screen, (1, 1) the
/// bottom-right. A layer's position is where its CENTER rests.
struct ScenePoint: Codable, Equatable {
    var x: Double = 0.5
    var y: Double = 0.5

    static let center = ScenePoint()
}

extension ScenePoint {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = container.sceneValue(.x, default: 0.5).clampedToUnit
        y = container.sceneValue(.y, default: 0.5).clampedToUnit
    }
}

struct SceneLayer: Codable, Equatable, Identifiable {
    /// Layer height may not exceed this fraction of the screen height.
    static let sizeRange: ClosedRange<Double> = 0.01...0.6

    var id = UUID()
    var isVisible: Bool = true
    var content: SceneLayerContent
    var position: ScenePoint = .center
    /// Fraction of the screen height (text: font size; icon: height).
    var size: Double = 0.1
    var opacity: Double = 1
    var motion = SceneMotion()
}

extension SceneLayer {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.sceneValue(.id, default: UUID())
        isVisible = container.sceneValue(.isVisible, default: true)
        content = try container.decode(SceneLayerContent.self, forKey: .content)
        position = container.sceneValue(.position, default: .center)
        let rawSize = container.sceneValue(.size, default: 0.1)
        size = min(max(rawSize, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        opacity = container.sceneValue(.opacity, default: 1).clampedToUnit
        motion = container.sceneValue(.motion, default: SceneMotion())
    }

    // Sensible defaults for every new layer (spec §10: UI-to-value rules).

    static func clock() -> SceneLayer {
        SceneLayer(content: .clock(ClockLayer()), size: 0.14)
    }

    static func text(_ string: String = "Be right back") -> SceneLayer {
        SceneLayer(content: .text(TextLayer(segments: [.text(string)])), size: 0.06)
    }

    static func icon(symbolName: String = "sparkles") -> SceneLayer {
        SceneLayer(content: .icon(IconLayer(symbolName: symbolName)), size: 0.12)
    }
}

enum SceneLayerContent: Equatable {
    case clock(ClockLayer)
    case text(TextLayer)
    case icon(IconLayer)
    /// A layer type this version doesn't know — preserved, never drawn.
    case unsupported(kind: String, payload: SceneJSONValue)

    /// Layers-list label.
    var displayName: String {
        switch self {
        case .clock: return "Clock"
        case .text: return "Text"
        case .icon: return "Icon"
        case .unsupported: return "Unsupported Layer"
        }
    }
}

extension SceneLayerContent: Codable {
    // Flat shape: {"kind": "clock", …the layer's own fields…}.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SceneCodingKey.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "clock": self = .clock(try ClockLayer(from: decoder))
        case "text": self = .text(try TextLayer(from: decoder))
        case "icon": self = .icon(try IconLayer(from: decoder))
        default: self = .unsupported(kind: kind, payload: try SceneJSONValue(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SceneCodingKey.self)
        switch self {
        case .clock(let clock):
            try clock.encode(to: encoder)
            try container.encode("clock", forKey: .kind)
        case .text(let text):
            try text.encode(to: encoder)
            try container.encode("text", forKey: .kind)
        case .icon(let icon):
            try icon.encode(to: encoder)
            try container.encode("icon", forKey: .kind)
        case .unsupported(_, let payload):
            try payload.encode(to: encoder)
        }
    }
}

struct SceneFont: Codable, Equatable {
    enum Design: String, Codable, CaseIterable, Identifiable {
        case system
        case rounded
        case serif
        case monospaced

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "Standard"
            case .rounded: return "Rounded"
            case .serif: return "Serif"
            case .monospaced: return "Mono"
            }
        }
    }

    enum Weight: String, Codable, CaseIterable, Identifiable {
        case light
        case regular
        case medium
        case semibold
        case bold

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .light: return "Light"
            case .regular: return "Regular"
            case .medium: return "Medium"
            case .semibold: return "Semibold"
            case .bold: return "Bold"
            }
        }
    }

    var design: Design = .rounded
    var weight: Weight = .semibold
    /// An installed font family (as listed in Font Book), e.g. "Futura".
    /// nil uses the system font in `design`. If the family isn't installed
    /// on the Mac showing the scene, the renderer falls back to `design`.
    var family: String?
}

extension SceneFont {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        design = container.sceneValue(.design, default: .rounded)
        weight = container.sceneValue(.weight, default: .semibold)
        family = container.sceneValue(.family, default: nil)
    }
}

struct ClockLayer: Codable, Equatable {
    var uses24Hour: Bool = false
    var showsSeconds: Bool = false
    /// Smaller date line under the time.
    var showsDate: Bool = false
    var font = SceneFont()
    var colorHex: String = "FFFFFF"
    var shadow: Bool = true
}

extension ClockLayer {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uses24Hour = container.sceneValue(.uses24Hour, default: false)
        showsSeconds = container.sceneValue(.showsSeconds, default: false)
        showsDate = container.sceneValue(.showsDate, default: false)
        font = container.sceneValue(.font, default: SceneFont())
        colorHex = container.sceneValue(.colorHex, default: "FFFFFF")
        shadow = container.sceneValue(.shadow, default: true)
    }
}

/// Live values a text layer can show. Inserted with buttons in Studio
/// ("+ Date", "+ Computer name", "+ Company name") — there is no typed
/// token syntax anywhere.
enum SceneTextToken: String, Codable, CaseIterable, Identifiable {
    case date
    case computerName
    case companyName

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .date: return "Date"
        case .computerName: return "Computer name"
        case .companyName: return "Company name"
        }
    }
}

/// A text layer is a run of literal text and tokens.
enum SceneTextSegment: Equatable {
    case text(String)
    case token(SceneTextToken)
}

extension SceneTextSegment: Codable {
    // {"text": "…"} or {"token": "date"}; an unknown token decodes to "".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SceneCodingKey.self)
        if let text = try? container.decode(String.self, forKey: "text") {
            self = .text(text)
        } else if let token = try? container.decode(SceneTextToken.self, forKey: "token") {
            self = .token(token)
        } else {
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SceneCodingKey.self)
        switch self {
        case .text(let text): try container.encode(text, forKey: "text")
        case .token(let token): try container.encode(token, forKey: "token")
        }
    }
}

extension Array where Element == SceneTextSegment {
    /// Merges neighbouring text runs and drops empty ones — the tidy form
    /// saved to disk after editing.
    var normalized: [SceneTextSegment] {
        var result: [SceneTextSegment] = []
        for segment in self {
            switch segment {
            case .text(let text):
                guard !text.isEmpty else { continue }
                if case .text(let previous)? = result.last {
                    result[result.count - 1] = .text(previous + text)
                } else {
                    result.append(segment)
                }
            case .token:
                result.append(segment)
            }
        }
        return result
    }
}

struct TextLayer: Codable, Equatable {
    var segments: [SceneTextSegment] = []
    var font = SceneFont()
    var colorHex: String = "FFFFFF"
    var shadow: Bool = true
}

extension TextLayer {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = container.sceneValue(.segments, default: [])
        font = container.sceneValue(.font, default: SceneFont())
        colorHex = container.sceneValue(.colorHex, default: "FFFFFF")
        shadow = container.sceneValue(.shadow, default: true)
    }
}

/// An SF Symbol, or an image file imported into the scene store. When
/// `imageAssetName` is set it wins; `colorHex` tints symbols only.
struct IconLayer: Codable, Equatable {
    var symbolName: String = "sparkles"
    var imageAssetName: String?
    var colorHex: String = "FFFFFF"
    var shadow: Bool = true
}

extension IconLayer {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbolName = container.sceneValue(.symbolName, default: "sparkles")
        imageAssetName = container.sceneValue(.imageAssetName, default: nil)
        colorHex = container.sceneValue(.colorHex, default: "FFFFFF")
        shadow = container.sceneValue(.shadow, default: true)
    }
}

// MARK: - Motion

/// How a layer moves. Everything is relative: `speed` is the Slow–Fast
/// slider (0–1), `intensity` is how far/strongly it moves (0–1). The
/// renderer turns these into points per second for the actual display
/// (see `SceneMotionMath`).
struct SceneMotion: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case still
        case bounce
        case drift
        case float
        case pulse
        case fade
        case orbit

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .still: return "Still"
            case .bounce: return "Bounce"
            case .drift: return "Drift"
            case .float: return "Float"
            case .pulse: return "Pulse"
            case .fade: return "Fade"
            case .orbit: return "Orbit"
            }
        }
    }

    var kind: Kind = .still
    var speed: Double = 0.35
    var intensity: Double = 0.5
    /// Bounce only: step through a color palette on every edge hit.
    var changesColorOnBounce: Bool = false
}

extension SceneMotion {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown motion (from a newer version) holds still.
        kind = container.sceneValue(.kind, default: .still)
        speed = container.sceneValue(.speed, default: 0.35).clampedToUnit
        intensity = container.sceneValue(.intensity, default: 0.5).clampedToUnit
        changesColorOnBounce = container.sceneValue(.changesColorOnBounce, default: false)
    }
}

// MARK: - Text resolution

/// The live values behind the text tokens, supplied by the host (app or
/// saver) at render time.
struct SceneTokenValues: Equatable {
    var computerName: String = ""
    var companyName: String = ""
}

enum SceneTextResolver {
    /// The string a text layer shows right now.
    static func resolve(_ segments: [SceneTextSegment],
                        values: SceneTokenValues,
                        date: Date,
                        locale: Locale = .current,
                        timeZone: TimeZone = .current) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): return text
            case .token(.date): return dateLine(for: date, locale: locale, timeZone: timeZone)
            case .token(.computerName): return values.computerName
            case .token(.companyName): return values.companyName
            }
        }.joined()
    }

    /// "Friday, October 2" in the given locale.
    static func dateLine(for date: Date,
                         locale: Locale = .current,
                         timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        style = style.weekday(.wide).month(.wide).day()
        return date.formatted(style)
    }
}

enum SceneClockFormatter {
    /// "9:41" / "09:41" (+ ":07" with seconds). 12-hour time carries no
    /// AM/PM marker — it's a screen saver clock, not a timestamp.
    static func timeString(for date: Date,
                           uses24Hour: Bool,
                           showsSeconds: Bool,
                           calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        var hour = parts.hour ?? 0
        if !uses24Hour {
            hour %= 12
            if hour == 0 { hour = 12 }
        }
        var string = String(format: uses24Hour ? "%02d:%02d" : "%d:%02d", hour, parts.minute ?? 0)
        if showsSeconds {
            string += String(format: ":%02d", parts.second ?? 0)
        }
        return string
    }

    /// Widest string the clock can show — layout measures this so the
    /// layer's bounds (and bounce edges) don't jitter as digits change.
    static func measuringTemplate(uses24Hour: Bool, showsSeconds: Bool) -> String {
        (uses24Hour ? "00:00" : "12:00") + (showsSeconds ? ":00" : "")
    }
}

// MARK: - Color

enum SceneColor {
    /// Parses "RRGGBB" or "#RRGGBB" (the same format as `fillColor`) into
    /// 0–1 sRGB components.
    static func components(hex: String) -> (red: Double, green: Double, blue: Double)? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }
}

// MARK: - Coding support

/// String-keyed coding key for the `kind`-discriminated shapes.
struct SceneCodingKey: CodingKey, ExpressibleByStringLiteral {
    static let kind: SceneCodingKey = "kind"

    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(stringLiteral value: String) { stringValue = value }
}

/// Arbitrary JSON, used to carry unknown `kind` payloads through a
/// load/save cycle untouched.
enum SceneJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SceneJSONValue])
    case object([String: SceneJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SceneJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SceneJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension KeyedDecodingContainer {
    /// Lenient read: a missing key, a wrong type, or an unrecognized enum
    /// value all fall back to the default.
    func sceneValue<Value: Decodable>(_ key: Key, default fallback: Value) -> Value {
        (try? decodeIfPresent(Value.self, forKey: key)) ?? fallback
    }
}

extension Double {
    var clampedToUnit: Double { Swift.min(1, Swift.max(0, self)) }
}
