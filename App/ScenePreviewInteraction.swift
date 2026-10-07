import AppKit
import ImageIO
import SwiftUI

/// The composer's live preview with direct manipulation: drag a text or
/// icon layer to move it; drag the picture to pan the Focus; pinch, or
/// scroll with a wheel or two-finger swipe, to zoom the picture (which
/// becomes a Fill crop around the focus). Edits land straight in the
/// scene, so the controls below follow.
struct InteractiveScenePreview: View {
    @Binding var scene: ScreenSaverScene
    let resources: SceneResources

    private enum DragTarget {
        case layer(index: Int, start: ScenePoint)
        case background(start: ScenePoint)
    }

    @State private var dragTarget: DragTarget?
    @State private var zoomAtPinchStart: Double?
    /// Pixel sizes of background and cutout images, by file, so overflow
    /// and hit-test math is cheap.
    @State private var pixelSizes: [URL: CGSize] = [:]
    @Environment(\.displayScale) private var displayScale

    static let zoomRange: ClosedRange<Double> = 1...4

    var body: some View {
        GeometryReader { proxy in
            let canvas = proxy.size
            SaverSceneView(scene: scene, resources: resources)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture(canvas: canvas))
                        .simultaneousGesture(magnifyGesture)
                    ScrollWheelMonitor { fingerUp in
                        applyZoom(factor: exp(fingerUp * 0.01))
                    }
                }
                .onAppear {
                    cachePixelSizes()
                }
                .onChange(of: scene.background.source) { _, _ in
                    cachePixelSizes()
                }
                .onChange(of: subjectURLs) { _, _ in
                    cachePixelSizes()
                }
        }
    }

    // MARK: Drag: move a layer, or pan the picture

    private func dragGesture(canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragTarget == nil {
                    dragTarget = target(at: value.startLocation, canvas: canvas)
                }
                guard canvas.width > 0, canvas.height > 0 else { return }
                switch dragTarget {
                case .layer(let index, let start):
                    guard scene.layers.indices.contains(index) else { return }
                    scene.layers[index].position = ScenePoint(
                        x: (start.x + value.translation.width / canvas.width).clampedToUnit,
                        y: (start.y + value.translation.height / canvas.height).clampedToUnit)
                case .background(let start):
                    let overflow = backgroundOverflow(canvas: canvas)
                    var focus = scene.background.treatment.focus
                    if overflow.width > 0 {
                        focus.x = (start.x - value.translation.width / overflow.width).clampedToUnit
                    }
                    if overflow.height > 0 {
                        focus.y = (start.y - value.translation.height / overflow.height).clampedToUnit
                    }
                    scene.background.treatment.focus = focus
                case nil:
                    break
                }
            }
            .onEnded { _ in
                dragTarget = nil
            }
    }

    /// Topmost visible layer under the point (at its resting position),
    /// else the background.
    private func target(at point: CGPoint, canvas: CGSize) -> DragTarget {
        for (index, layer) in scene.layers.enumerated().reversed() where layer.isVisible {
            // A pinned subject moves with the picture, not on its own.
            if case .subject(let subject) = layer.content, subject.isPinned { continue }
            let pointSize = max(1, layer.size * canvas.height)
            let size = measuredSize(of: layer, pointSize: pointSize)
            let center = CGPoint(x: layer.position.x * canvas.width, y: layer.position.y * canvas.height)
            let slop: CGFloat = 8
            let rect = CGRect(x: center.x - size.width / 2 - slop, y: center.y - size.height / 2 - slop,
                              width: size.width + slop * 2, height: size.height + slop * 2)
            if rect.contains(point) {
                return .layer(index: index, start: layer.position)
            }
        }
        return .background(start: scene.background.treatment.focus)
    }

    private func measuredSize(of layer: SceneLayer, pointSize: CGFloat) -> CGSize {
        switch layer.content {
        case .clock(let clock):
            return SceneLayerMetrics.clockSize(clock, pointSize: pointSize,
                                               dateLine: SceneTextResolver.dateLine(for: Date()))
        case .text(let text):
            return SceneLayerMetrics.textSize(SceneTextResolver.resolve(text.segments, values: resources.tokens, date: Date()),
                                              font: text.font, pointSize: pointSize)
        case .icon:
            return CGSize(width: pointSize, height: pointSize)
        case .subject(let subject):
            guard let url = resources.assetURL(subject.imageAssetName),
                  let pixels = pixelSizes[url] else {
                return CGSize(width: pointSize, height: pointSize)
            }
            let crop = subject.bounds?.pixelRect(in: pixels) ?? CGRect(origin: .zero, size: pixels)
            guard crop.height > 0 else { return CGSize(width: pointSize, height: pointSize) }
            return CGSize(width: pointSize * crop.width / crop.height, height: pointSize)
        case .unsupported:
            return .zero
        }
    }

    // MARK: Zoom: pinch, wheel, two-finger swipe

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomAtPinchStart == nil {
                    zoomAtPinchStart = scene.background.treatment.zoom
                }
                setZoom((zoomAtPinchStart ?? 1) * value.magnification)
            }
            .onEnded { _ in
                zoomAtPinchStart = nil
            }
    }

    private func applyZoom(factor: Double) {
        setZoom(scene.background.treatment.zoom * factor)
    }

    /// Zooming only means something for a cropping mode; from Fit, Fit +
    /// Blur, or Stretch the first zoom switches to Fill.
    private func setZoom(_ zoom: Double) {
        let clamped = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        var treatment = scene.background.treatment
        if treatment.scaleMode != .fill && treatment.scaleMode != .center {
            guard clamped > 1 else { return }
            treatment.scaleMode = .fill
        }
        treatment.zoom = clamped
        scene.background.treatment = treatment
    }

    // MARK: Background geometry

    /// How much of the picture lies outside the canvas on each axis, in
    /// preview points — what the Focus slides across.
    private func backgroundOverflow(canvas: CGSize) -> CGSize {
        guard let url = backgroundURL(), let pixels = pixelSizes[url], pixels.width > 0, pixels.height > 0 else {
            return .zero
        }
        let treatment = scene.background.treatment
        switch treatment.scaleMode {
        case .fill:
            let scale = max(canvas.width / pixels.width, canvas.height / pixels.height) * treatment.zoom
            return CGSize(width: max(0, pixels.width * scale - canvas.width),
                          height: max(0, pixels.height * scale - canvas.height))
        case .center:
            let scale = treatment.zoom / displayScale
            return CGSize(width: max(0, pixels.width * scale - canvas.width),
                          height: max(0, pixels.height * scale - canvas.height))
        case .fit, .fitBlur, .stretch:
            return .zero
        }
    }

    private func backgroundURL() -> URL? {
        switch scene.background.source {
        case .currentDesktop: return resources.currentDesktopURL()
        case .wallpaper(let id): return resources.wallpaperURL(id)
        case .rotatingPool: return resources.rotationURLs().first
        case .image(let name): return resources.assetURL(name)
        case .solid, .gradient, .unsupported: return nil
        }
    }

    /// Cutout files of the scene's subject layers (hit-testing needs
    /// their aspect ratio).
    private var subjectURLs: [URL] {
        scene.layers.compactMap { layer in
            guard case .subject(let subject) = layer.content else { return nil }
            return resources.assetURL(subject.imageAssetName)
        }
    }

    private func cachePixelSizes() {
        let urls = ([backgroundURL()].compactMap { $0 } + subjectURLs).filter { pixelSizes[$0] == nil }
        for url in Set(urls) {
            Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else { return }
                let size = CGSize(width: width, height: height)
                await MainActor.run {
                    pixelSizes[url] = size
                }
            }
        }
    }
}

/// Reports scroll-wheel and two-finger-swipe motion over its bounds as
/// "finger up" units (positive = fingers moved up, whatever the natural
/// scrolling setting), and swallows those events so the page behind
/// doesn't scroll. Click-through: it never takes the mouse.
struct ScrollWheelMonitor: NSViewRepresentable {
    let onScroll: (Double) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        context.coordinator.install(on: view, onScroll: onScroll)
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class MonitorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var onScroll: ((Double) -> Void)?
        private var monitor: Any?

        func install(on view: MonitorView, onScroll: @escaping (Double) -> Void) {
            self.onScroll = onScroll
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
                guard let self, let view, let window = view.window, event.window == window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                var delta = event.scrollingDeltaY
                if !event.hasPreciseScrollingDeltas {
                    delta *= 4   // a mouse wheel ticks in whole lines
                }
                // Natural scrolling reports fingers-up as a negative delta.
                let fingerUp = event.isDirectionInvertedFromDevice ? -delta : delta
                if fingerUp != 0 {
                    self.onScroll?(fingerUp)
                }
                return nil
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
