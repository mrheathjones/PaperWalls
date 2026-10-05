import Foundation

/// Built-in starting points for Studio's "New Wallpaper" flow. Read-only
/// templates — a preset only becomes a design when the user saves it.
/// Wallpapers are still images, so every layer is `.still`.
enum WallpaperPreset: String, CaseIterable, Identifiable {
    case softGradient
    case companyBadge
    case helpDesk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .softGradient: return "Soft Gradient"
        case .companyBadge: return "Company Badge"
        case .helpDesk: return "Help Desk"
        }
    }

    /// "Blank": a dark solid color, nothing on it.
    static var blankScene: ScreenSaverScene {
        ScreenSaverScene(background: SceneBackground(source: .solid(colorHex: "1C1C24")))
    }

    var scene: ScreenSaverScene {
        switch self {
        case .softGradient:
            return ScreenSaverScene(
                background: SceneBackground(source: .gradient(startHex: "1E3A5F", endHex: "0B1026",
                                                              angleDegrees: 60)))

        case .companyBadge:
            var badge = SceneLayer.icon(symbolName: "building.2.fill")
            badge.position = ScenePoint(x: 0.5, y: 0.42)
            badge.size = 0.16
            var name = SceneLayer(content: .text(TextLayer(segments: [.token(.companyName)],
                                                           font: SceneFont(design: .rounded, weight: .semibold))),
                                  position: ScenePoint(x: 0.5, y: 0.6),
                                  size: 0.06)
            name.opacity = 0.95
            return ScreenSaverScene(
                background: SceneBackground(source: .gradient(startHex: "2B1B4A", endHex: "0B1026",
                                                              angleDegrees: 120)),
                layers: [badge, name])

        case .helpDesk:
            var ring = SceneLayer.icon(symbolName: "lifepreserver")
            ring.position = ScenePoint(x: 0.5, y: 0.27)
            ring.size = 0.12
            var headline = SceneLayer.text("Need help?")
            headline.content = .text(TextLayer(segments: [.text("Need help?")],
                                               font: SceneFont(design: .system, weight: .bold)))
            headline.position = ScenePoint(x: 0.5, y: 0.42)
            headline.size = 0.07
            let detail = SceneLayer(content: .text(TextLayer(segments: [.text("Contact the "),
                                                                        .token(.companyName),
                                                                        .text(" Service Desk")],
                                                             font: SceneFont(design: .system, weight: .regular),
                                                             shadow: false)),
                                    position: ScenePoint(x: 0.5, y: 0.52),
                                    size: 0.035,
                                    opacity: 0.85)
            return ScreenSaverScene(
                background: SceneBackground(source: .solid(colorHex: "0F172A")),
                layers: [ring, headline, detail])
        }
    }
}
