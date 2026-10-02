import ScreenSaver
import SwiftUI
import SystemConfiguration
import os

/// The .saver's principal class (spec §10). Hosts the same `SaverSceneView`
/// the app previews with, inside the system's legacyScreenSaver process.
///
/// PHASE 2 SPIKE: shows a hardcoded scene and runs `SaverProbe` so we can
/// see, with evidence, what the sandboxed host can read. Scene delivery is
/// decided from those findings.
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
        SaverProbe.event("deinit")
    }

    private func configure() {
        // SwiftUI's timeline drives the frames; the host's own timer only
        // needs to tick occasionally.
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        SaverProbe.event("init preview=\(isPreview) frame=\(Int(frame.width))x\(Int(frame.height))")

        willStopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.willStopNotification, object: nil, queue: .main) { [weak self] _ in
            SaverProbe.event("willstop notification")
            self?.tearDownScene()
        }
    }

    // MARK: - ScreenSaverView

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func startAnimation() {
        super.startAnimation()
        SaverProbe.event("startAnimation preview=\(isPreview)")
        installScene()
        SaverProbe.runOnce(bundle: Bundle(for: PaperWallsSaverView.self), screen: window?.screen)
    }

    override func stopAnimation() {
        super.stopAnimation()
        SaverProbe.event("stopAnimation preview=\(isPreview)")
        tearDownScene()
    }

    override func animateOneFrame() {
        // Nothing to do — see `configure()`.
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    // MARK: - Scene hosting

    private func installScene() {
        guard hostingView == nil else { return }
        let screen = window?.screen ?? NSScreen.main
        let resources = SceneResources(
            currentDesktopURL: {
                screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            },
            tokens: SceneTokenValues(
                computerName: (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "",
                companyName: ManagedPreferences.string(.companyName) ?? ""))
        // Spike: hardcoded scene.
        let host = NSHostingView(rootView: SaverSceneView(scene: ScreenSaverPreset.bouncingClock.scene,
                                                          resources: resources))
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
