import AppKit
import SwiftUI
import SystemConfiguration

/// Shows a scene in its own window (spec §10) — a resizable preview, or
/// fullscreen exactly as the saver would draw it (any key or click
/// dismisses). Hosts the same `SaverSceneView` the saver uses.
@MainActor
enum ScenePreviewPresenter {
    private static var windows: [ScenePreviewWindow] = []

    static func show(scene: ScreenSaverScene,
                     resources: SceneResources,
                     title: String = "Scene Preview",
                     fullscreen: Bool = false) {
        let window: ScenePreviewWindow
        if fullscreen, let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            window = ScenePreviewWindow(contentRect: screen.frame,
                                        styleMask: [.borderless],
                                        backing: .buffered,
                                        defer: false)
            window.level = .mainMenu + 1
            window.dismissesOnInput = true
            window.setFrame(screen.frame, display: false)
        } else {
            window = ScenePreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                        backing: .buffered,
                                        defer: false)
            window.title = title
            window.contentMinSize = NSSize(width: 480, height: 300)
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: SaverSceneView(scene: scene, resources: resources))
        window.onClose = { [weak window] in
            // Tear the hosting view down so the scene releases its images.
            window?.contentView = nil
            windows.removeAll { $0 === window }
        }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class ScenePreviewWindow: NSWindow {
    var dismissesOnInput = false
    var onClose: (() -> Void)?

    // Borderless windows refuse key status by default.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if dismissesOnInput {
            close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if dismissesOnInput {
            close()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }
}

extension AppModel {
    /// What a scene needs from the running app: library lookups, the
    /// current desktop picture, the resolved rotation pool (spec §4 — so
    /// lock tiers and the allow-list apply to rotating backgrounds), and
    /// the token values.
    var sceneResources: SceneResources {
        let library = self.library
        let pool = rotationPool
        return SceneResources(
            wallpaperURL: { id in
                library.wallpaper(withID: id).flatMap { library.fileURL(for: $0) }
            },
            currentDesktopURL: {
                (NSScreen.main ?? NSScreen.screens.first).flatMap { WallpaperEngine.currentWallpaperURL(for: $0) }
            },
            rotationURLs: {
                pool.compactMap { library.fileURL(for: $0) }
            },
            tokens: SceneTokenValues(
                computerName: (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "",
                companyName: prefs.companyName.trimmingCharacters(in: .whitespaces)))
    }
}

/// DEBUG-only menu for eyeballing the renderer until the ScreenSavers
/// page and Studio exist (spec §10, phase 1).
struct ScenePreviewCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Scene Preview") {
            ForEach(ScreenSaverPreset.allCases) { preset in
                Button(preset.displayName) {
                    ScenePreviewPresenter.show(scene: preset.scene,
                                               resources: model.sceneResources,
                                               title: preset.displayName)
                }
            }
            Divider()
            Button("Rotating Pool") {
                var scene = ScreenSaverPreset.bouncingClock.scene
                scene.background = SceneBackground(
                    source: .rotatingPool(intervalSeconds: 8),
                    treatment: SceneBackgroundTreatment(dim: 0.3, slowZoom: true))
                ScenePreviewPresenter.show(scene: scene, resources: model.sceneResources,
                                           title: "Rotating Pool")
            }
            Button("Bouncing Clock — Fullscreen") {
                ScenePreviewPresenter.show(scene: ScreenSaverPreset.bouncingClock.scene,
                                           resources: model.sceneResources,
                                           fullscreen: true)
            }
        }
    }
}
