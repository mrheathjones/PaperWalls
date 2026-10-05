import ScreenSaver
import SwiftUI
import SystemConfiguration
import os

/// The .saver's principal class (spec §10). Hosts the same `SaverSceneView`
/// the app previews with, inside the system's legacyScreenSaver process.
///
/// What to show comes from `ScreenSaverSnapshot` — the one file the app
/// and `paperwallscli manage` publish for the saver. This sandboxed host
/// can't see the preference domain, so it never evaluates policy itself:
///   * active        → the snapshot's scene
///   * none selected / no snapshot yet → the built-in Minimal Clock
///   * disabled / hard lock → a solid color, nothing else
/// The snapshot is re-read every time the saver starts.
///
/// The explicit @objc name keeps `NSPrincipalClass` free of the Swift
/// module prefix — and unique, since every installed saver is loaded into
/// the one host process.
@objc(PaperWallsSaverView)
final class PaperWallsSaverView: ScreenSaverView {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "saver")

    /// Posted by the system when the screen saver is dismissed. Recent
    /// macOS releases don't reliably call `stopAnimation` on dismissal, so
    /// this is the second trigger for releasing resources.
    private static let willStopNotification = Notification.Name("com.apple.screensaver.willstop")

    private var hostingView: NSHostingView<SaverSceneView>?
    /// Solid color shown when there is no scene (disabled / hard lock).
    private var fallbackColor = NSColor.black
    private var willStopObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        if let willStopObserver {
            DistributedNotificationCenter.default().removeObserver(willStopObserver)
        }
    }

    private func configure() {
        // SwiftUI's timeline drives the frames; the host's own timer only
        // needs to tick occasionally.
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        #if DEBUG
        SaverProbe.event("init preview=\(isPreview) frame=\(Int(frame.width))x\(Int(frame.height))")
        #endif

        willStopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.willStopNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tearDownScene()
        }
    }

    // MARK: - ScreenSaverView

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func startAnimation() {
        super.startAnimation()
        installScene()
        #if DEBUG
        // Sandbox probe for verifying new macOS versions (debug builds only).
        SaverProbe.event("startAnimation preview=\(isPreview)")
        SaverProbe.runOnce(bundle: Bundle(for: PaperWallsSaverView.self), screen: window?.screen)
        #endif
    }

    override func stopAnimation() {
        super.stopAnimation()
        tearDownScene()
    }

    override func animateOneFrame() {
        // Nothing to do — see `configure()`.
    }

    override func draw(_ rect: NSRect) {
        fallbackColor.setFill()
        rect.fill()
    }

    // MARK: - Scene hosting

    /// For a scene bundle (a renamed copy standing for one scene) the
    /// per-copy identity hook answers with the copy's own path; the main
    /// saver has no such method.
    ///
    /// Ask the Objective-C runtime for the class: Swift's `type(of:)`
    /// skips runtime-created subclasses and answers PaperWallsSaverView,
    /// which made every copy fall back to the active scene.
    private var sceneBundlePath: String? {
        let selector = NSSelectorFromString("paperwallsBundlePath")
        guard let cls = object_getClass(self) as? NSObject.Type, cls.responds(to: selector) else {
            return nil
        }
        return cls.perform(selector)?.takeUnretainedValue() as? String
    }

    private func installScene() {
        guard hostingView == nil else { return }
        let snapshot: ScreenSaverSnapshot?
        if let path = sceneBundlePath {
            // A scene bundle carries its own resolved snapshot.
            let url = URL(fileURLWithPath: path).appendingPathComponent("Contents/Resources/\(ScreenSaverSnapshot.bundledFilename)")
            // Deployed bundles carry their images with bundle-relative paths.
            snapshot = ScreenSaverSnapshot.read(from: url)?
                .resolvingBundlePaths(in: url.deletingLastPathComponent())
            Self.log.info("Scene bundle \(path, privacy: .public) → \(snapshot?.sceneName ?? "no snapshot", privacy: .public)")
        } else {
            snapshot = ScreenSaverSnapshot.read()
        }
        let scene: ScreenSaverScene
        switch snapshot?.state {
        case .active?:
            // An "active" snapshot always carries its scene; fall back to
            // the default rather than a blank screen if one ever doesn't.
            scene = snapshot?.scene ?? ScreenSaverPreset.minimalClock.scene
        case .disabled?, .hardLock?:
            // Policy says show nothing: just the solid color from draw(_:).
            fallbackColor = snapshot.flatMap { NSColor(sceneHex: $0.fallbackColorHex) } ?? .black
            layer?.backgroundColor = fallbackColor.cgColor
            needsDisplay = true
            Self.log.info("Showing a solid color (\(snapshot?.state.rawValue ?? "", privacy: .public))")
            return
        case .noneSelected?, nil:
            scene = ScreenSaverPreset.minimalClock.scene
        }

        let screen = window?.screen ?? NSScreen.main
        let resources = SceneResources(
            wallpaperURL: { id in
                snapshot?.wallpaperPaths[id].map { URL(fileURLWithPath: $0) }
            },
            currentDesktopURL: {
                screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            },
            rotationURLs: {
                (snapshot?.rotationPaths ?? []).map { URL(fileURLWithPath: $0) }
            },
            assetURL: { name in
                snapshot?.assetURL(named: name)
            },
            tokens: SceneTokenValues(
                computerName: (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "",
                companyName: snapshot?.companyName ?? ""))
        let host = NSHostingView(rootView: SaverSceneView(scene: scene, resources: resources))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        hostingView = host
    }

    /// Drops the SwiftUI hierarchy, which releases the decoded images.
    private func tearDownScene() {
        hostingView?.removeFromSuperview()
        hostingView = nil
    }
}

private extension NSColor {
    /// "RRGGBB" scene color.
    convenience init?(sceneHex hex: String) {
        guard let parts = SceneColor.components(hex: hex) else { return nil }
        self.init(srgbRed: parts.red, green: parts.green, blue: parts.blue, alpha: 1)
    }
}
