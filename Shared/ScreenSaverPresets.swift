import Foundation

/// Built-in starting points for Studio's "New Screen Saver" flow
/// (spec §10). Read-only templates — a preset only becomes a library
/// entry when the user saves it.
enum ScreenSaverPreset: String, CaseIterable, Identifiable {
    case bouncingClock
    case floatingMessage
    case minimalClock
    case helpDeskContact

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bouncingClock: return "Bouncing Clock"
        case .floatingMessage: return "Floating Message"
        case .minimalClock: return "Minimal Clock"
        case .helpDeskContact: return "Help Desk Contact"
        }
    }

    var scene: ScreenSaverScene {
        switch self {
        case .bouncingClock:
            var clock = SceneLayer.clock()
            clock.motion = SceneMotion(kind: .bounce, speed: 0.3, changesColorOnBounce: true)
            return ScreenSaverScene(
                background: SceneBackground(source: .currentDesktop,
                                            treatment: SceneBackgroundTreatment(blur: 0.25, dim: 0.45)),
                layers: [clock])

        case .floatingMessage:
            var message = SceneLayer.text("Be right back")
            message.size = 0.08
            message.motion = SceneMotion(kind: .float, speed: 0.3, intensity: 0.5)
            return ScreenSaverScene(
                background: SceneBackground(source: .gradient(startHex: "2B1B4A", endHex: "0B1026",
                                                              angleDegrees: 60)),
                layers: [message])

        case .minimalClock:
            var clock = SceneLayer.clock()
            clock.content = .clock(ClockLayer(showsDate: true,
                                              font: SceneFont(design: .system, weight: .light),
                                              shadow: false))
            clock.size = 0.16
            clock.opacity = 0.9
            // A barely-there wander so the clock never rests on the same
            // pixels for hours.
            clock.motion = SceneMotion(kind: .drift, speed: 0.1, intensity: 0.15)
            return ScreenSaverScene(
                background: SceneBackground(source: .solid(colorHex: "0B0B0F")),
                layers: [clock])

        case .helpDeskContact:
            var icon = SceneLayer.icon(symbolName: "lifepreserver")
            icon.position = ScenePoint(x: 0.5, y: 0.3)
            icon.motion = SceneMotion(kind: .pulse, speed: 0.2, intensity: 0.2)

            // Tokens sit on their own lines so an unset company name
            // leaves no dangling words behind.
            var company = SceneLayer(content: .text(TextLayer(
                segments: [.token(.companyName)],
                font: SceneFont(design: .rounded, weight: .medium))), size: 0.035)
            company.position = ScenePoint(x: 0.5, y: 0.43)
            company.opacity = 0.85

            var headline = SceneLayer.text("Need help? Contact the Help Desk")
            headline.size = 0.055
            headline.position = ScenePoint(x: 0.5, y: 0.5)

            var machine = SceneLayer(content: .text(TextLayer(
                segments: [.text("This Mac: "), .token(.computerName)],
                font: SceneFont(design: .monospaced, weight: .regular))), size: 0.03)
            machine.position = ScenePoint(x: 0.5, y: 0.58)
            machine.opacity = 0.8

            var clock = SceneLayer.clock()
            clock.size = 0.05
            clock.position = ScenePoint(x: 0.5, y: 0.88)
            clock.opacity = 0.85

            return ScreenSaverScene(
                background: SceneBackground(source: .currentDesktop,
                                            treatment: SceneBackgroundTreatment(blur: 0.5, dim: 0.6)),
                layers: [icon, company, headline, machine, clock])
        }
    }
}
