import AppKit
import os

/// Scaling modes matching desktoppr's `fill | fit | stretch | center` values.
/// Tiling has no NSWorkspace equivalent, so it is intentionally not offered.
enum WallpaperScale: String, CaseIterable, Identifiable {
    case fill
    case fit
    case stretch
    case center

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fill: return "Fill Screen"
        case .fit: return "Fit to Screen"
        case .stretch: return "Stretch"
        case .center: return "Center"
        }
    }

    /// `NSWorkspace.setDesktopImageURL` options equivalent to this mode.
    func workspaceOptions(fillColor: NSColor?) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any]
        switch self {
        case .fill:
            options = [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                       .allowClipping: true]
        case .fit:
            options = [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                       .allowClipping: false]
        case .stretch:
            options = [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
                       .allowClipping: true]
        case .center:
            options = [.imageScaling: NSImageScaling.scaleNone.rawValue,
                       .allowClipping: false]
        }
        if let fillColor {
            options[.fillColor] = fillColor
        }
        return options
    }
}

enum WallpaperError: Error, LocalizedError {
    case invalidFile(String)
    case noScreens
    case noSuchScreen(Int)
    case setFailed(path: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let path):
            return "No readable image file at \(path)."
        case .noScreens:
            return "No displays found. Setting a wallpaper requires a logged-in GUI session."
        case .noSuchScreen(let index):
            return "No display at index \(index)."
        case .setFailed(let path, let underlying):
            return "Failed to set \(path): \(underlying.localizedDescription)"
        }
    }
}

/// Thin wrapper around NSWorkspace's desktop-image API, shared by GUI and CLI.
enum WallpaperEngine {
    // FUTURE: route through PaperLog multi-sink (spec §9, deferred).
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "engine")

    /// desktoppr pauses between consecutive set calls because rapid
    /// back-to-back calls to setDesktopImageURL intermittently fail on
    /// multi-display systems; match that workaround.
    static let interScreenDelay: TimeInterval = 1.0

    static func currentWallpaperURL(for screen: NSScreen) -> URL? {
        NSWorkspace.shared.desktopImageURL(for: screen)
    }

    static func screen(at index: Int) throws -> NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw WallpaperError.noScreens }
        guard screens.indices.contains(index) else { throw WallpaperError.noSuchScreen(index) }
        return screens[index]
    }

    /// Synchronous apply used by the CLI. Blocks the calling thread for
    /// `interScreenDelay` between displays.
    static func setWallpaper(url: URL,
                             on screens: [NSScreen],
                             scale: WallpaperScale = .fill,
                             fillColor: NSColor? = nil) throws {
        try validate(url: url)
        guard !screens.isEmpty else { throw WallpaperError.noScreens }
        let options = scale.workspaceOptions(fillColor: fillColor)
        for (offset, screen) in screens.enumerated() {
            if offset > 0 { Thread.sleep(forTimeInterval: interScreenDelay) }
            try set(url: url, screen: screen, options: options)
        }
    }

    /// Async apply used by the GUI so the inter-screen delay never blocks
    /// the main thread.
    @MainActor
    static func setWallpaper(url: URL,
                             on screens: [NSScreen],
                             scale: WallpaperScale = .fill,
                             fillColor: NSColor? = nil) async throws {
        try validate(url: url)
        guard !screens.isEmpty else { throw WallpaperError.noScreens }
        let options = scale.workspaceOptions(fillColor: fillColor)
        for (offset, screen) in screens.enumerated() {
            if offset > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interScreenDelay * 1_000_000_000))
            }
            try set(url: url, screen: screen, options: options)
        }
    }

    private static func set(url: URL,
                            screen: NSScreen,
                            options: [NSWorkspace.DesktopImageOptionKey: Any]) throws {
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            log.info("Set \(url.path, privacy: .public) on \(screen.localizedName, privacy: .public)")
        } catch {
            log.error("Failed to set \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw WallpaperError.setFailed(path: url.path, underlying: error)
        }
    }

    private static func validate(url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw WallpaperError.invalidFile(url.path)
        }
    }
}

extension NSColor {
    /// Parses "RRGGBB" or "#RRGGBB", the format used by the fillColor preference.
    convenience init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
