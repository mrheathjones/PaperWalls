import AppKit
import SwiftUI

/// Everything a scene needs from its host (the app or the saver) to turn
/// IDs and tokens into files and strings. Closures keep the renderer free
/// of any dependency on the library, preferences, or the scene store.
struct SceneResources {
    /// File for a library wallpaper ID.
    var wallpaperURL: (String) -> URL? = { _ in nil }
    /// Whatever the desktop picture is right now.
    var currentDesktopURL: () -> URL? = { nil }
    /// The resolved rotation pool (spec §4), in rotation order.
    var rotationURLs: () -> [URL] = { [] }
    /// File for an image imported into the scene store.
    var assetURL: (String) -> URL? = { _ in nil }
    var tokens = SceneTokenValues()

    static let empty = SceneResources()
}

/// The live scene renderer (spec §10): the Studio preview, the fullscreen
/// preview, and the saver all host this one view. Frames are capped at
/// ~30 fps and every frame is a pure function of the clock — the view
/// keeps no animation state.
struct SaverSceneView: View {
    static let frameInterval: TimeInterval = 1.0 / 30.0

    let scene: ScreenSaverScene
    var resources: SceneResources = .empty
    var isPaused: Bool = false

    @Environment(\.displayScale) private var displayScale
    @StateObject private var imageStore = SceneImageStore()
    @State private var startDate = Date()
    @State private var backgroundURLs: [URL] = []

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: Self.frameInterval, paused: isPaused)) { context in
                let time = context.date.timeIntervalSince(startDate)
                let phase = backgroundPhase(time: time)
                SceneFrameView(scene: scene,
                               date: context.date,
                               time: time,
                               size: proxy.size,
                               background: SceneFrameBackground(
                                   current: phase.current.flatMap { imageStore.images[$0] },
                                   next: phase.next.flatMap { imageStore.images[$0] },
                                   blend: phase.blend),
                               tokens: resources.tokens,
                               assetImage: { name in
                                   resources.assetURL(name).flatMap { imageStore.images[$0] }
                               })
                    .task(id: ImageRequest(urls: phase.urls + assetURLs,
                                           maxPixelSize: maxPixelSize(for: proxy.size))) {
                        await imageStore.prepare(phase.urls + assetURLs,
                                                 maxPixelSize: maxPixelSize(for: proxy.size))
                    }
            }
        }
        .background(Color.black)
        .onAppear(perform: resolveBackgroundURLs)
        .onChange(of: scene.background.source) { _, _ in
            resolveBackgroundURLs()
        }
        .onDisappear {
            imageStore.releaseAll()
        }
    }

    private struct ImageRequest: Hashable {
        let urls: [URL]
        let maxPixelSize: Int
    }

    /// Resolved once per source change, not per frame.
    private func resolveBackgroundURLs() {
        switch scene.background.source {
        case .currentDesktop:
            backgroundURLs = [resources.currentDesktopURL()].compactMap { $0 }
        case .wallpaper(let id):
            backgroundURLs = [resources.wallpaperURL(id)].compactMap { $0 }
        case .rotatingPool:
            backgroundURLs = resources.rotationURLs()
        case .image(let name):
            backgroundURLs = [resources.assetURL(name)].compactMap { $0 }
        case .solid, .gradient, .unsupported:
            backgroundURLs = []
        }
    }

    /// The image(s) on screen at `time`. Only a rotating pool has a
    /// `next`: it is preloaded for the whole interval, then crossfaded in.
    private func backgroundPhase(time: TimeInterval) -> (current: URL?, next: URL?, blend: Double, urls: [URL]) {
        guard !backgroundURLs.isEmpty else { return (nil, nil, 0, []) }
        guard case .rotatingPool(let interval) = scene.background.source, backgroundURLs.count > 1 else {
            return (backgroundURLs[0], nil, 0, [backgroundURLs[0]])
        }
        let phase = SceneMotionMath.rotationPhase(time: time, interval: interval, count: backgroundURLs.count)
        let current = backgroundURLs[phase.current]
        let next = backgroundURLs[phase.next]
        return (current, next, phase.blend, [current, next])
    }

    private var assetURLs: [URL] {
        scene.layers.compactMap { layer in
            guard layer.isVisible, case .icon(let icon) = layer.content,
                  let name = icon.imageAssetName else { return nil }
            return resources.assetURL(name)
        }
    }

    private func maxPixelSize(for size: CGSize) -> Int {
        SceneImageLoader.pixelBucket(for: max(size.width, size.height) * displayScale)
    }
}

/// The background image(s) for one frame.
struct SceneFrameBackground {
    var current: CGImage?
    var next: CGImage?
    /// Opacity of `next` over `current` (rotating-pool crossfade).
    var blend: Double = 0
}

/// One frame of a scene: no clock, no loading, no state. `SaverSceneView`
/// drives it live; thumbnails render it once at a fixed instant with
/// `ImageRenderer`.
struct SceneFrameView: View {
    let scene: ScreenSaverScene
    /// Wall-clock time (what the clock layer shows).
    let date: Date
    /// Seconds since the scene started (what motion is computed from).
    let time: TimeInterval
    let size: CGSize
    var background = SceneFrameBackground()
    var tokens = SceneTokenValues()
    var assetImage: (String) -> CGImage? = { _ in nil }

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            backgroundView
            ForEach(scene.layers.filter(\.isVisible)) { layer in
                layerView(layer)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    // MARK: - Background

    private var backgroundView: some View {
        let treatment = scene.background.treatment
        let zoom = treatment.slowZoom ? SceneMotionMath.slowZoom(time: time) : (scale: 1, offset: .zero)
        // Blur radius scales with the canvas so the look matches on any display.
        let blurRadius = treatment.blur * 0.04 * size.height
        return backgroundContent
            .frame(width: size.width, height: size.height)
            .clipped()
            .scaleEffect(zoom.scale)
            .offset(x: zoom.offset.x * size.width, y: zoom.offset.y * size.height)
            .blur(radius: blurRadius, opaque: true)
            .overlay(Color.black.opacity(treatment.dim))
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    @ViewBuilder
    private var backgroundContent: some View {
        switch scene.background.source {
        case .solid(let colorHex):
            Color(sceneHex: colorHex, fallback: .black)
        case .gradient(let startHex, let endHex, let angleDegrees):
            let radians = angleDegrees * .pi / 180
            let direction = CGPoint(x: cos(radians) / 2, y: sin(radians) / 2)
            LinearGradient(colors: [Color(sceneHex: startHex, fallback: .black),
                                    Color(sceneHex: endHex, fallback: .black)],
                           startPoint: UnitPoint(x: 0.5 - direction.x, y: 0.5 - direction.y),
                           endPoint: UnitPoint(x: 0.5 + direction.x, y: 0.5 + direction.y))
        case .currentDesktop, .wallpaper, .rotatingPool, .image:
            ZStack {
                Color.black
                if let current = background.current {
                    backgroundImage(current)
                }
                if let next = background.next, background.blend > 0 {
                    backgroundImage(next)
                        .opacity(background.blend)
                }
            }
        case .unsupported:
            Color.black
        }
    }

    @ViewBuilder
    private func backgroundImage(_ image: CGImage) -> some View {
        switch scene.background.treatment.scaleMode {
        case .fill:
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
        case .fit:
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
        case .fitBlur:
            ZStack {
                // Enlarged so the blur's soft edges fall outside the canvas.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(1.2)
                    .blur(radius: size.height * 0.05, opaque: true)
                    .overlay(Color.black.opacity(0.2))
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        case .stretch:
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
        case .center:
            Image(decorative: image, scale: displayScale)
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private func layerView(_ layer: SceneLayer) -> some View {
        // Relative size → points for THIS canvas.
        let pointSize = max(1, layer.size * size.height)
        let state = SceneMotionMath.state(motion: layer.motion,
                                          anchor: layer.position,
                                          layerSize: measuredSize(of: layer, pointSize: pointSize),
                                          canvas: size,
                                          time: time)
        layerContent(layer, pointSize: pointSize, bounceCount: state.bounceCount)
            .fixedSize()
            .scaleEffect(state.scale)
            .opacity(layer.opacity * state.opacity)
            .position(state.center)
    }

    @ViewBuilder
    private func layerContent(_ layer: SceneLayer, pointSize: CGFloat, bounceCount: Int) -> some View {
        switch layer.content {
        case .clock(let clock):
            VStack(spacing: pointSize * SceneLayerMetrics.clockDateSpacing) {
                Text(SceneClockFormatter.timeString(for: date,
                                                    uses24Hour: clock.uses24Hour,
                                                    showsSeconds: clock.showsSeconds))
                    .font(clock.font.font(size: pointSize))
                    .monospacedDigit()
                if clock.showsDate {
                    Text(SceneTextResolver.dateLine(for: date))
                        .font(clock.font.font(size: pointSize * SceneLayerMetrics.clockDateScale))
                }
            }
            .foregroundStyle(color(clock.colorHex, for: layer, bounceCount: bounceCount))
            .sceneShadow(clock.shadow, pointSize: pointSize)
        case .text(let text):
            Text(SceneTextResolver.resolve(text.segments, values: tokens, date: date))
                .font(text.font.font(size: pointSize))
                .multilineTextAlignment(.center)
                .foregroundStyle(color(text.colorHex, for: layer, bounceCount: bounceCount))
                .sceneShadow(text.shadow, pointSize: pointSize)
        case .icon(let icon):
            if let name = icon.imageAssetName {
                if let image = assetImage(name) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(height: pointSize)
                        .sceneShadow(icon.shadow, pointSize: pointSize)
                }
            } else {
                Image(systemName: icon.symbolName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: pointSize, height: pointSize)
                    .foregroundStyle(color(icon.colorHex, for: layer, bounceCount: bounceCount))
                    .sceneShadow(icon.shadow, pointSize: pointSize)
            }
        case .unsupported:
            EmptyView()
        }
    }

    /// The layer's own color — or, for "change color on bounce", the
    /// palette color for the edge hits so far.
    private func color(_ hex: String, for layer: SceneLayer, bounceCount: Int) -> Color {
        guard layer.motion.kind == .bounce, layer.motion.changesColorOnBounce, bounceCount > 0 else {
            return Color(sceneHex: hex)
        }
        return Color(sceneHex: SceneMotionMath.bounceColorHex(bounceCount: bounceCount))
    }

    private func measuredSize(of layer: SceneLayer, pointSize: CGFloat) -> CGSize {
        switch layer.content {
        case .clock(let clock):
            return SceneLayerMetrics.clockSize(clock, pointSize: pointSize, dateLine: SceneTextResolver.dateLine(for: date))
        case .text(let text):
            return SceneLayerMetrics.textSize(SceneTextResolver.resolve(text.segments, values: tokens, date: date),
                                              font: text.font, pointSize: pointSize)
        case .icon(let icon):
            guard let name = icon.imageAssetName else {
                return CGSize(width: pointSize, height: pointSize)
            }
            guard let image = assetImage(name), image.height > 0 else { return .zero }
            return CGSize(width: pointSize * CGFloat(image.width) / CGFloat(image.height), height: pointSize)
        case .unsupported:
            return .zero
        }
    }
}

// MARK: - Layer metrics

/// Text measurement for motion bounds. SwiftUI lays the text out itself;
/// this only tells the motion math how big the layer is, so the bounce
/// edges land where the glyphs do.
enum SceneLayerMetrics {
    /// Date line size and gap, as fractions of the clock's point size.
    static let clockDateScale: CGFloat = 0.28
    static let clockDateSpacing: CGFloat = 0.02

    static func textSize(_ string: String, font: SceneFont, pointSize: CGFloat) -> CGSize {
        guard !string.isEmpty else { return .zero }
        let size = (string as NSString).size(withAttributes: [.font: font.nsFont(size: pointSize)])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    static func clockSize(_ clock: ClockLayer, pointSize: CGFloat, dateLine: String) -> CGSize {
        let template = SceneClockFormatter.measuringTemplate(uses24Hour: clock.uses24Hour,
                                                             showsSeconds: clock.showsSeconds)
        var size = textSize(template, font: clock.font, pointSize: pointSize)
        if clock.showsDate {
            let date = textSize(dateLine, font: clock.font, pointSize: pointSize * clockDateScale)
            size.width = max(size.width, date.width)
            size.height += pointSize * clockDateSpacing + date.height
        }
        return size
    }
}

// MARK: - Model → SwiftUI/AppKit

/// Installed font families (what Font Book lists), cached — the renderer
/// asks on every frame.
enum SceneFontLibrary {
    static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    private static let familySet = Set(families)

    static func isInstalled(_ family: String) -> Bool {
        familySet.contains(family)
    }
}

extension SceneFont {
    /// The chosen family when it's installed here, else nil (system font).
    var installedFamily: String? {
        guard let family, SceneFontLibrary.isInstalled(family) else { return nil }
        return family
    }

    func font(size: CGFloat) -> Font {
        if let installedFamily {
            return .custom(installedFamily, fixedSize: size).weight(weight.fontWeight)
        }
        return .system(size: size, weight: weight.fontWeight, design: design.fontDesign)
    }

    func nsFont(size: CGFloat) -> NSFont {
        if let installedFamily,
           let font = NSFontManager.shared.font(withFamily: installedFamily, traits: [],
                                                weight: weight.fontManagerWeight, size: size) {
            return font
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight.nsFontWeight)
        guard let systemDesign = design.nsFontDesign,
              let descriptor = base.fontDescriptor.withDesign(systemDesign),
              let font = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return font
    }
}

extension SceneFont.Design {
    var fontDesign: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }

    var nsFontDesign: NSFontDescriptor.SystemDesign? {
        switch self {
        case .system: return nil
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

extension SceneFont.Weight {
    var fontWeight: Font.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    /// NSFontManager's 0–15 scale (5 is regular, 9 is bold).
    var fontManagerWeight: Int {
        switch self {
        case .light: return 3
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        }
    }

    var nsFontWeight: NSFont.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

extension Color {
    /// Scene colors are "RRGGBB" hex strings; an unparseable value falls
    /// back rather than failing the layer.
    init(sceneHex hex: String, fallback: Color = .white) {
        if let parts = SceneColor.components(hex: hex) {
            self.init(.sRGB, red: parts.red, green: parts.green, blue: parts.blue)
        } else {
            self = fallback
        }
    }
}

private extension View {
    /// Soft drop shadow sized to the layer, so text stays legible over
    /// any background.
    func sceneShadow(_ enabled: Bool, pointSize: CGFloat) -> some View {
        shadow(color: .black.opacity(enabled ? 0.45 : 0),
               radius: pointSize * 0.06,
               y: pointSize * 0.02)
    }
}
