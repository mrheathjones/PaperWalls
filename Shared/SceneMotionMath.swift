import CoreGraphics
import Foundation

/// Where one layer is at one instant.
struct SceneLayerState: Equatable {
    /// Layer center, in points, in the canvas' top-left coordinate space.
    var center: CGPoint
    var scale: Double = 1
    /// Multiplies the layer's own opacity.
    var opacity: Double = 1
    /// Edge hits so far (bounce only) — drives "change color on bounce".
    var bounceCount: Int = 0
}

/// Motion math for scene layers (spec §10). Every function is PURE: a
/// layer's state is a function of time alone, so there is no per-frame
/// state to keep, drift, or restore — the preview, thumbnails, and the
/// saver all compute the same frame for the same instant.
///
/// Scene values are relative (0–1); the conversions to points and points
/// per second for the actual canvas happen here.
enum SceneMotionMath {
    /// Vertical speed as a fraction of horizontal for bounce — different
    /// per-axis velocities keep the path from retracing a single diagonal.
    static let bounceAxisRatio = 0.73

    /// Colors stepped through by "change color on bounce".
    static let bouncePalette = ["FFFFFF", "F25571", "FFB45E", "FFE066", "5EE6A8", "5EC8FF", "B58CFF"]

    static func lerp(_ low: Double, _ high: Double, _ t: Double) -> Double {
        low + (high - low) * t.clampedToUnit
    }

    /// Slow–Fast slider → points per second. Scaled by the canvas height
    /// so a layer crosses any display in the same time.
    static func linearSpeed(_ speed: Double, canvasHeight: Double) -> Double {
        canvasHeight * lerp(0.03, 0.45, speed)
    }

    /// Slow–Fast slider → radians per second for the cyclic motions.
    static func angularSpeed(_ speed: Double) -> Double {
        2 * .pi * lerp(0.02, 0.4, speed)
    }

    /// Ping-pong: maps an ever-growing travelled `distance` onto
    /// `0...range` and counts the edge hits along the way.
    static func triangleWave(distance: Double, range: Double) -> (position: Double, bounces: Int) {
        guard range > 0 else { return (0, 0) }
        let travelled = max(0, distance)
        let period = 2 * range
        let phase = travelled.truncatingRemainder(dividingBy: period)
        return (phase <= range ? phase : period - phase, Int(travelled / range))
    }

    /// The layer's state at `time` seconds since the scene started.
    /// `anchor` is the layer's resting center (unit space); `layerSize` is
    /// its measured size in points.
    static func state(motion: SceneMotion,
                      anchor: ScenePoint,
                      layerSize: CGSize,
                      canvas: CGSize,
                      time: TimeInterval) -> SceneLayerState {
        let rest = CGPoint(x: anchor.x * canvas.width, y: anchor.y * canvas.height)
        let time = max(0, time)
        let omega = angularSpeed(motion.speed)

        switch motion.kind {
        case .still:
            return SceneLayerState(center: rest)

        case .bounce:
            // Triangle wave per axis over the travel range of the layer's
            // origin, starting from the resting position.
            let rangeX = max(0, canvas.width - layerSize.width)
            let rangeY = max(0, canvas.height - layerSize.height)
            let startX = min(max(0, rest.x - layerSize.width / 2), rangeX)
            let startY = min(max(0, rest.y - layerSize.height / 2), rangeY)
            let velocity = linearSpeed(motion.speed, canvasHeight: canvas.height)
            let x = triangleWave(distance: startX + velocity * time, range: rangeX)
            let y = triangleWave(distance: startY + velocity * bounceAxisRatio * time, range: rangeY)
            return SceneLayerState(center: CGPoint(x: x.position + layerSize.width / 2,
                                                   y: y.position + layerSize.height / 2),
                                   bounceCount: x.bounces + y.bounces)

        case .drift:
            // Slow wander around the resting point; the two frequencies
            // are incommensurate so the path doesn't visibly repeat.
            let reach = lerp(0.05, 0.35, motion.intensity)
            let offset = CGPoint(x: sin(omega * time * 0.31) * reach * canvas.width,
                                 y: sin(omega * time * 0.47 + 1.3) * reach * canvas.height)
            return SceneLayerState(center: clamped(CGPoint(x: rest.x + offset.x, y: rest.y + offset.y),
                                                   layerSize: layerSize, canvas: canvas))

        case .float:
            // Gentle bob with a slight sway.
            let reach = lerp(0.005, 0.06, motion.intensity) * canvas.height
            let offset = CGPoint(x: sin(omega * time * 0.5) * reach * 0.35,
                                 y: sin(omega * time) * reach)
            return SceneLayerState(center: clamped(CGPoint(x: rest.x + offset.x, y: rest.y + offset.y),
                                                   layerSize: layerSize, canvas: canvas))

        case .pulse:
            let amount = lerp(0.02, 0.25, motion.intensity)
            return SceneLayerState(center: rest, scale: 1 + amount * sin(omega * time))

        case .fade:
            // Starts fully visible, dips by up to `intensity`.
            let dip = lerp(0.15, 1, motion.intensity)
            return SceneLayerState(center: rest, opacity: 1 - dip * (0.5 - 0.5 * cos(omega * time)))

        case .orbit:
            let radius = lerp(0.02, 0.3, motion.intensity) * canvas.height
            let center = CGPoint(x: rest.x + cos(omega * time) * radius,
                                 y: rest.y + sin(omega * time) * radius)
            return SceneLayerState(center: clamped(center, layerSize: layerSize, canvas: canvas))
        }
    }

    /// Keeps a layer fully on screen (or centered when it's bigger than
    /// the canvas on that axis).
    static func clamped(_ center: CGPoint, layerSize: CGSize, canvas: CGSize) -> CGPoint {
        func clamp(_ value: Double, half: Double, extent: Double) -> Double {
            guard extent > half * 2 else { return extent / 2 }
            return min(max(value, half), extent - half)
        }
        return CGPoint(x: clamp(center.x, half: layerSize.width / 2, extent: canvas.width),
                       y: clamp(center.y, half: layerSize.height / 2, extent: canvas.height))
    }

    /// Palette color for a bounce count (wraps).
    static func bounceColorHex(bounceCount: Int) -> String {
        bouncePalette[max(0, bounceCount) % bouncePalette.count]
    }

    // MARK: - Background

    static let minimumRotationInterval: TimeInterval = 5
    static let rotationFadeDuration: TimeInterval = 2

    /// Which pool images are on screen at `time`: `current` is fully
    /// drawn, `next` is drawn over it at `blend` (0 outside the crossfade
    /// window at the end of each interval). `next` is also the image to
    /// preload.
    static func rotationPhase(time: TimeInterval,
                              interval: TimeInterval,
                              count: Int,
                              fadeDuration: TimeInterval = rotationFadeDuration) -> (current: Int, next: Int, blend: Double) {
        guard count > 0 else { return (0, 0, 0) }
        let interval = max(minimumRotationInterval, interval)
        let fade = min(fadeDuration, interval / 2)
        let time = max(0, time)
        let step = Int(time / interval)
        let elapsed = time - Double(step) * interval
        let fadeStart = interval - fade
        let blend = (fade > 0 && elapsed > fadeStart) ? (elapsed - fadeStart) / fade : 0
        return (step % count, (step + 1) % count, blend.clampedToUnit)
    }

    /// Slow zoom/pan ("Ken Burns"). `offset` is a fraction of the canvas;
    /// the scale always leaves enough overscan to cover it.
    static func slowZoom(time: TimeInterval) -> (scale: Double, offset: CGPoint) {
        let time = max(0, time)
        let breath = 0.5 - 0.5 * cos(2 * .pi * time / 90)
        return (1.03 + 0.08 * breath,
                CGPoint(x: 0.01 * sin(2 * .pi * time / 120),
                        y: 0.01 * sin(2 * .pi * time / 150)))
    }
}
