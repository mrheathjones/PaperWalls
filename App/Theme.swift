import AppKit
import SwiftUI

/// Design tokens matching the PaperWalls mockups: warm cream canvas, white
/// cards, coral accent, generous rounded corners. Colors are dynamic so the
/// Settings → Theme (Light/Dark) choice restyles the whole window.
enum Theme {
    // Colors
    static let background = dynamic(light: NSColor(red: 0.953, green: 0.937, blue: 0.914, alpha: 1),
                                    dark: NSColor(red: 0.113, green: 0.108, blue: 0.102, alpha: 1))
    static let card = dynamic(light: .white,
                              dark: NSColor(red: 0.172, green: 0.166, blue: 0.158, alpha: 1))
    static let hairline = dynamic(light: NSColor.black.withAlphaComponent(0.08),
                                  dark: NSColor.white.withAlphaComponent(0.10))
    static let chipFill = dynamic(light: NSColor.black.withAlphaComponent(0.05),
                                  dark: NSColor.white.withAlphaComponent(0.09))
    static let selectedRow = dynamic(light: NSColor.black.withAlphaComponent(0.045),
                                     dark: NSColor.white.withAlphaComponent(0.08))
    static let accent = Color(red: 0.949, green: 0.333, blue: 0.443)

    // Source icon gradients
    static let personalIcon = LinearGradient(colors: [Color(red: 1.0, green: 0.72, blue: 0.45),
                                                      Color(red: 0.98, green: 0.55, blue: 0.35)],
                                             startPoint: .top, endPoint: .bottom)
    static let managedIcon = LinearGradient(colors: [Color(red: 0.62, green: 0.55, blue: 0.98),
                                                     Color(red: 0.48, green: 0.40, blue: 0.95)],
                                            startPoint: .top, endPoint: .bottom)
    static let systemIcon = LinearGradient(colors: [Color(red: 0.44, green: 0.72, blue: 1.0),
                                                    Color(red: 0.25, green: 0.51, blue: 0.96)],
                                           startPoint: .top, endPoint: .bottom)

    // Corner radii
    static let cardRadius: CGFloat = 18
    static let heroRadius: CGFloat = 20
    static let panelRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10

    // Type
    static let pageTitle = Font.system(size: 32, weight: .bold)
    static let cardName = Font.system(size: 16, weight: .semibold)
    static let cardNameMono = Font.system(size: 14, weight: .semibold, design: .monospaced)
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 13)
    static let pathMono = Font.system(size: 13, design: .monospaced)
    static let badge = Font.system(size: 11, weight: .bold)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// The theme is applied app-wide via NSApp.appearance (AppModel.
// applyAppearance) — SwiftUI's preferredColorScheme(nil) never un-pins an
// explicit scheme on macOS, which broke live "System" switching.
