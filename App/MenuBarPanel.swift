import AppKit
import SwiftUI

/// The menu bar popover panel — styled with the app's design language:
/// cream canvas, white cards, coral accent, rounded corners. Shows the
/// auto-rotate state, a preview of what's coming next, and quick actions.
struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            rotateCard
            if prefs.autoRotateEnabled, let next = model.upNext.first {
                upNextSection(next: next)
            }
            actionButtons
            footer
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.background)
        .tint(Theme.accent)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            }
            Text("PaperWalls")
                .font(.system(size: 15, weight: .bold))
            Spacer()
        }
    }

    // MARK: - Auto-rotate

    private var rotateCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-Rotate")
                    .font(.system(size: 14, weight: .semibold))
                Text(model.rotationStatusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SettingsToggle(isOn: $prefs.autoRotateEnabled,
                           disabled: prefs.isForced(.autoRotateEnabled) || model.selectionLocked)
                .controlSize(.small)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }

    // MARK: - Up next

    @ViewBuilder
    private func upNextSection(next: CuratedWallpaper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UP NEXT")
                .font(Theme.sectionLabel)
                .tracking(1.5)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topTrailing) {
                WallpaperThumbnail(url: model.library.thumbnailURL(for: next), maxPixelSize: 640)
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                       .init(color: .clear, location: 0.6)],
                               startPoint: .bottom, endPoint: .top)
                if let minutes = nextChangeMinutes {
                    Text("in \(minutes) min")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(8)
                }
                VStack {
                    Spacer()
                    HStack(alignment: .center) {
                        Text(next.displayName)
                            .font(next.source == .bundled ? .system(size: 14, weight: .semibold)
                                                          : .system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                        Spacer()
                        // Same action as the app's "Next" button: apply the
                        // previewed wallpaper now and restart the countdown.
                        SetButton(label: "Next", systemImage: "forward.end.fill") {
                            model.applyNextWallpaper()
                        }
                        .disabled(model.isApplying || model.selectionLocked)
                        .help("Set this wallpaper now")
                    }
                    .padding(10)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture(perform: openApp)

            let upcoming = Array(model.upNext.dropFirst().prefix(3))
            if !upcoming.isEmpty {
                HStack(spacing: 8) {
                    ForEach(upcoming) { wallpaper in
                        WallpaperThumbnail(url: model.library.thumbnailURL(for: wallpaper), maxPixelSize: 240)
                            .frame(height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .help(wallpaper.displayName)
                    }
                }
            }
        }
    }

    private var nextChangeMinutes: Int? {
        guard let due = model.nextRotationDate else { return nil }
        return max(1, Int(ceil(due.timeIntervalSince(model.now) / 60)))
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 10) {
            PanelButton(label: "Rotate Now",
                        systemImage: "arrow.2.circlepath",
                        prominent: true,
                        action: model.rotateNowManually)
                .disabled(model.rotationPool.isEmpty || model.isApplying || model.selectionLocked)
            PanelButton(label: "Open App",
                        systemImage: "macwindow",
                        prominent: false,
                        action: openApp)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit PaperWalls") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func openApp() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Pill button in the panel: coral filled (prominent) or neutral chip fill.
struct PanelButton: View {
    @Environment(\.isEnabled) private var isEnabled

    let label: String
    let systemImage: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.chipFill),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}
