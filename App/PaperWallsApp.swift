import AppKit
import SwiftUI

@main
struct PaperWallsApp: App {
    @StateObject private var prefs: PreferencesStore
    @StateObject private var model: AppModel

    init() {
        let prefs = PreferencesStore()
        _prefs = StateObject(wrappedValue: prefs)
        _model = StateObject(wrappedValue: AppModel(prefs: prefs))
    }

    var body: some Scene {
        // A single library window (not a WindowGroup) so the menu bar item
        // can always bring the same window forward.
        Window("PaperWalls", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(prefs)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 840)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
                .environmentObject(prefs)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(prefs)
        }
    }

    /// The app icon rendered at status-item size (18 pt; the drawing handler
    /// re-renders at the menu bar's backing scale, so Retina stays crisp).
    private static var menuBarIcon: NSImage {
        let appIcon = NSApp.applicationIconImage ?? NSImage()
        return NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            appIcon.draw(in: rect)
            return true
        }
    }
}
