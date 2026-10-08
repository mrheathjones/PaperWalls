import AppKit
import SwiftUI

/// What the composer is making. The control views hide what doesn't
/// apply: a wallpaper is a still image, so no motion and no live
/// (current-desktop / rotating) backgrounds.
enum SceneComposerKind {
    case screenSaver
    case wallpaper
}

private struct SceneComposerKindKey: EnvironmentKey {
    static let defaultValue: SceneComposerKind = .screenSaver
}

private struct ComposerPixelSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 2560, height: 1600)
}

extension EnvironmentValues {
    var composerKind: SceneComposerKind {
        get { self[SceneComposerKindKey.self] }
        set { self[SceneComposerKindKey.self] = newValue }
    }

    /// The pixel size the composition targets (a wallpaper's output size,
    /// or the main display for a screen saver).
    var composerPixelSize: CGSize {
        get { self[ComposerPixelSizeKey.self] }
        set { self[ComposerPixelSizeKey.self] = newValue }
    }
}

// Scene Composer controls (spec §10: UI-to-value rules). Every control
// binds straight to the scene model — a Picker for the motion, Slow–Fast
// sliders for relative speeds, toggles for options. Exact numbers live
// behind "Advanced"; nothing here asks the user to type a value format.

// MARK: - Building blocks

/// Labelled group of rows in a card, matching the Settings cards.
struct ComposerSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.sectionLabel)
                .tracking(1.5)
                .foregroundStyle(.secondary)
            SettingsCard {
                content
            }
        }
    }
}

/// Title on the left, any control on the right.
struct ComposerRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Slider with word labels at each end ("Slow" … "Fast").
struct ComposerSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var lowLabel: String
    var highLabel: String

    var body: some View {
        ComposerRow(title: title) {
            HStack(spacing: 8) {
                Text(lowLabel)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $value, in: range)
                    .frame(minWidth: 140, maxWidth: 240)
                    .tint(Theme.accent)
                    .accessibilityLabel(title)
                Text(highLabel)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Color well plus quick swatches, bound to a scene "RRGGBB" string.
struct ComposerColorRow: View {
    let title: String
    @Binding var hex: String

    private let swatches = ["FFFFFF", "000000", "F25571", "FFB45E", "FFE066", "5EE6A8", "5EC8FF", "B58CFF"]

    var body: some View {
        ComposerRow(title: title) {
            HStack(spacing: 6) {
                ForEach(swatches, id: \.self) { swatch in
                    Button {
                        hex = swatch
                    } label: {
                        Circle()
                            .fill(Color(sceneHex: swatch))
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle().strokeBorder(hex.uppercased() == swatch ? Theme.accent : Theme.hairline,
                                                      lineWidth: hex.uppercased() == swatch ? 2 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(swatch)")
                }
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel(title)
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(sceneHex: hex) },
                set: { hex = $0.sceneHexString })
    }
}

/// Exact-number field for the Advanced disclosure, shown as a percentage.
struct ComposerPercentField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        ComposerRow(title: title) {
            HStack(spacing: 4) {
                TextField("", value: percentBinding, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain)
                    .font(Theme.pathMono)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel(title)
                Text("%")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var percentBinding: Binding<Double> {
        Binding(get: { value * 100 },
                set: { value = min(max($0 / 100, range.lowerBound), range.upperBound) })
    }
}

extension Color {
    /// "RRGGBB" for the scene model.
    var sceneHexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X",
                      Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()),
                      Int((color.blueComponent * 255).rounded()))
    }
}

// MARK: - Layer controls

struct SceneLayerControls: View {
    @Binding var layer: SceneLayer
    /// The scene's background — a subject layer can swap its photo in.
    var background: Binding<SceneBackground>?

    @Environment(\.composerKind) private var kind
    @State private var showsAdvanced = false

    /// A pinned subject has no size, position or motion of its own: it
    /// follows the background.
    private var isPinnedSubject: Bool {
        if case .subject(let subject) = layer.content { return subject.isPinned }
        return false
    }

    var body: some View {
        // The sections sit side by side so the whole form is visible
        // without scrolling past the preview.
        HStack(alignment: .top, spacing: 18) {
            contentSection
                .frame(maxWidth: .infinity, alignment: .topLeading)

            if isPinnedSubject {
                ComposerSection(title: "Size & Position") {
                    Text("A pinned subject keeps its place in the photo. Drag the picture in the preview, or change the background’s fit, focus and zoom, and the subject follows. Unpin it to move or resize it on its own.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .padding(16)
                    SettingsDivider()
                    ComposerSlider(title: "Opacity", value: $layer.opacity,
                                   lowLabel: "Faint", highLabel: "Solid")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
            ComposerSection(title: "Size & Position") {
                ComposerSlider(title: "Size", value: $layer.size, range: sizeSliderRange,
                               lowLabel: "Small", highLabel: "Large")
                SettingsDivider()
                ComposerSlider(title: "Across", value: $layer.position.x,
                               lowLabel: "Left", highLabel: "Right")
                SettingsDivider()
                ComposerSlider(title: "Down", value: $layer.position.y,
                               lowLabel: "Top", highLabel: "Bottom")
                SettingsDivider()
                ComposerSlider(title: "Opacity", value: $layer.opacity,
                               lowLabel: "Faint", highLabel: "Solid")
                SettingsDivider()
                advanced
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if kind == .screenSaver && !isPinnedSubject {
                ComposerSection(title: "Motion") {
                    ComposerRow(title: "Motion") {
                        Picker("Motion", selection: $layer.motion.kind) {
                            ForEach(SceneMotion.Kind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if layer.motion.kind != .still {
                        SettingsDivider()
                        ComposerSlider(title: "Speed", value: $layer.motion.speed,
                                       lowLabel: "Slow", highLabel: "Fast")
                    }
                    if usesIntensity {
                        SettingsDivider()
                        ComposerSlider(title: intensityTitle, value: $layer.motion.intensity,
                                       lowLabel: "Subtle", highLabel: "Strong")
                    }
                    if layer.motion.kind == .bounce {
                        SettingsDivider()
                        ComposerRow(title: "Change color on bounce") {
                            SettingsToggle(isOn: $layer.motion.changesColorOnBounce)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Text and icons cap at 40% of the screen; a subject can fill it.
    private var sizeSliderRange: ClosedRange<Double> {
        if case .subject = layer.content { return SceneLayer.subjectSizeRange }
        return 0.02...0.4
    }

    /// Exact numbers for the sliders above, tucked at the bottom of the
    /// Size & Position card.
    private var advanced: some View {
        DisclosureGroup(isExpanded: $showsAdvanced) {
            VStack(spacing: 0) {
                ComposerPercentField(title: "Size (of screen height)", value: $layer.size,
                                     range: SceneLayer.sizeRange(for: layer.content))
                SettingsDivider()
                ComposerPercentField(title: "Across", value: $layer.position.x)
                SettingsDivider()
                ComposerPercentField(title: "Down", value: $layer.position.y)
                SettingsDivider()
                ComposerPercentField(title: "Opacity", value: $layer.opacity)
                if kind == .screenSaver {
                    SettingsDivider()
                    ComposerPercentField(title: "Speed", value: $layer.motion.speed)
                    SettingsDivider()
                    ComposerPercentField(title: "Motion strength", value: $layer.motion.intensity)
                }
            }
            .padding(.horizontal, -16)
            .padding(.top, 4)
        } label: {
            // The whole title toggles it, not just the chevron.
            Button("Advanced") {
                showsAdvanced.toggle()
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Bounce covers the whole screen and Still doesn't move — neither
    /// has a "how far" to adjust.
    private var usesIntensity: Bool {
        layer.motion.kind != .still && layer.motion.kind != .bounce
    }

    private var intensityTitle: String {
        switch layer.motion.kind {
        case .pulse: return "Pulse amount"
        case .fade: return "Fade amount"
        default: return "Range"
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        switch layer.content {
        case .clock(let clock):
            ClockLayerControls(clock: contentBinding(clock, wrap: SceneLayerContent.clock))
        case .text(let text):
            TextLayerControls(text: contentBinding(text, wrap: SceneLayerContent.text))
        case .icon(let icon):
            IconLayerControls(icon: contentBinding(icon, wrap: SceneLayerContent.icon))
        case .subject(let subject):
            SubjectLayerControls(subject: contentBinding(subject, wrap: SceneLayerContent.subject),
                                 background: background)
        case .unsupported:
            ComposerSection(title: "Layer") {
                Text("This layer was made with a newer version of PaperWalls. It is kept as-is but can't be edited here.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
    }

    /// Binding into the payload of the layer's content case.
    private func contentBinding<Value>(_ current: Value,
                                       wrap: @escaping (Value) -> SceneLayerContent) -> Binding<Value> {
        Binding(get: { current },
                set: { layer.content = wrap($0) })
    }
}

struct SceneFontRows: View {
    @Binding var font: SceneFont
    /// Text the font list previews each font with ("12" for a clock).
    var sample: String?

    var body: some View {
        ComposerRow(title: "Font") {
            FontFamilyPicker(font: $font, sample: sample)
        }
        SettingsDivider()
        // Thin → heavy, one notch per weight, like the lock-screen clock's
        // weight slider. The Font chip above is set in the chosen weight,
        // so the slider's effect shows as it's dragged.
        ComposerRow(title: "Weight") {
            HStack(spacing: 8) {
                Text("Thin")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Slider(value: weightIndex, in: 0...Double(SceneFont.Weight.allCases.count - 1), step: 1)
                    .frame(minWidth: 140, maxWidth: 240)
                    .tint(Theme.accent)
                    .help(font.weight.displayName)
                    .accessibilityLabel("Weight")
                    .accessibilityValue(font.weight.displayName)
                Text("Heavy")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var weightIndex: Binding<Double> {
        let weights = SceneFont.Weight.allCases
        return Binding(
            get: { Double(weights.firstIndex(of: font.weight) ?? 0) },
            set: { value in
                let index = min(max(Int(value.rounded()), 0), weights.count - 1)
                if weights[index] != font.weight {
                    font.weight = weights[index]
                }
            })
    }
}

struct ClockLayerControls: View {
    @Binding var clock: ClockLayer

    var body: some View {
        ComposerSection(title: "Clock") {
            ComposerRow(title: "24-hour time") {
                SettingsToggle(isOn: $clock.uses24Hour)
            }
            SettingsDivider()
            ComposerRow(title: "Show seconds") {
                SettingsToggle(isOn: $clock.showsSeconds)
            }
            SettingsDivider()
            ComposerRow(title: "Show date") {
                SettingsToggle(isOn: $clock.showsDate)
            }
            SettingsDivider()
            SceneFontRows(font: $clock.font, sample: "12")
            SettingsDivider()
            ComposerColorRow(title: "Color", hex: $clock.colorHex)
            SettingsDivider()
            ComposerRow(title: "Shadow") {
                SettingsToggle(isOn: $clock.shadow)
            }
        }
    }
}

struct TextLayerControls: View {
    @Binding var text: TextLayer

    var body: some View {
        ComposerSection(title: "Text") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(text.segments.enumerated()), id: \.offset) { index, segment in
                    segmentRow(index: index, segment: segment)
                }
                // Live values are inserted with buttons — never typed.
                // They wrap, since the Text card shares the row with
                // Size & Position and Motion.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 6, alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    Button("+ Text") {
                        text.segments.append(.text(""))
                    }
                    ForEach(SceneTextToken.allCases) { token in
                        Button("+ \(token.displayName)") {
                            text.segments.append(.token(token))
                        }
                    }
                }
                .controlSize(.small)
            }
            .padding(16)
            SettingsDivider()
            SceneFontRows(font: $text.font)
            SettingsDivider()
            ComposerColorRow(title: "Color", hex: $text.colorHex)
            SettingsDivider()
            ComposerRow(title: "Shadow") {
                SettingsToggle(isOn: $text.shadow)
            }
        }
    }

    @ViewBuilder
    private func segmentRow(index: Int, segment: SceneTextSegment) -> some View {
        HStack(spacing: 8) {
            switch segment {
            case .text:
                TextField("", text: textBinding(at: index), prompt: Text("Type text"))
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 8))
            case .token(let token):
                Label(token.displayName, systemImage: "curlybraces")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent, in: Capsule())
                Spacer(minLength: 0)
            }
            Button {
                guard text.segments.indices.contains(index) else { return }
                text.segments.remove(at: index)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove this part")
        }
    }

    private func textBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard text.segments.indices.contains(index),
                      case .text(let string) = text.segments[index] else { return "" }
                return string
            },
            set: { newValue in
                guard text.segments.indices.contains(index),
                      case .text = text.segments[index] else { return }
                text.segments[index] = .text(newValue)
            })
    }
}

struct IconLayerControls: View {
    @EnvironmentObject private var model: AppModel

    @Binding var icon: IconLayer

    @State private var importError: String?

    private let symbols = [
        "sparkles", "star.fill", "heart.fill", "moon.stars.fill", "sun.max.fill", "cloud.fill",
        "bolt.fill", "flame.fill", "leaf.fill", "globe", "lock.fill", "lifepreserver",
        "phone.fill", "envelope.fill", "building.2.fill", "person.fill", "desktopcomputer", "laptopcomputer",
        "wifi", "bell.fill", "cup.and.saucer.fill", "music.note", "gamecontroller.fill", "apple.logo",
    ]

    private let columns = [GridItem(.adaptive(minimum: 38), spacing: 8)]

    var body: some View {
        ComposerSection(title: "Icon") {
            if let assetName = icon.imageAssetName {
                ComposerRow(title: "Image") {
                    HStack(spacing: 8) {
                        if let asset = model.brandAsset(forAssetName: assetName) {
                            Text(asset.name)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 180)
                        } else {
                            Text(assetName)
                                .font(Theme.pathMono)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 180)
                        }
                        Button("Use a Symbol") {
                            icon.imageAssetName = nil
                        }
                    }
                }
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            icon.symbolName = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 16))
                                .frame(width: 38, height: 34)
                                .foregroundStyle(icon.symbolName == symbol ? .white : .primary)
                                .background(icon.symbolName == symbol ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.chipFill),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol)
                    }
                }
                .padding(16)
                SettingsDivider()
                ComposerRow(title: icon.symbolName) {
                    SymbolBrowserButton(symbolName: $icon.symbolName)
                }
                SettingsDivider()
                ComposerColorRow(title: "Color", hex: $icon.colorHex)
            }
            if !model.allBrandAssets.isEmpty {
                SettingsDivider()
                ComposerRow(title: "Brand Assets") {
                    EmptyView()
                }
                BrandAssetPicker(selectedAssetName: icon.imageAssetName) { assetName in
                    icon.imageAssetName = assetName
                }
            }
            SettingsDivider()
            ComposerRow(title: "Use your own image") {
                HStack(spacing: 8) {
                    PhotoLibraryButton(onPicked: importPhoto) {
                        Text("From Photos…")
                    }
                    Button("Choose Image…", action: chooseImage)
                }
            }
            SettingsDivider()
            ComposerRow(title: "Shadow") {
                SettingsToggle(isOn: $icon.shadow)
            }
        }
        .alert("Couldn’t Add Image", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    /// The image is copied into the library, so the scene doesn't depend
    /// on where the original file lives.
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            icon.imageAssetName = try ScreenSaverSceneStore.importAsset(from: url)
        } catch {
            importError = "That file couldn’t be added. Choose a PNG, JPEG, HEIC, TIFF, or GIF image."
        }
    }

    /// A photo from the Photos picker, stored upright like a background
    /// photo (an icon is rarely a 48 MP shot, but a sideways one would
    /// draw sideways otherwise).
    private func importPhoto(data: Data) {
        do {
            icon.imageAssetName = try PhotoImporter.importPhoto(data: data).assetName
        } catch {
            importError = error.localizedDescription
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }
}

// MARK: - AI Prompt

/// "Describe a background and generate it": sits under the Name field in
/// the composer whatever is selected, since the result always replaces
/// the background (shown whole, with a blurred fill behind it). Shows
/// nothing when no AI service is turned on.
struct SceneAIPromptSection: View {
    @EnvironmentObject private var prefs: PreferencesStore

    @Binding var background: SceneBackground

    @Environment(\.composerPixelSize) private var pixelSize

    var body: some View {
        if prefs.aiPolicy.offersGeneration {
            ComposerSection(title: "AI Prompt") {
                AIBackgroundGenerator(policy: prefs.aiPolicy, pixelSize: pixelSize) { assetName in
                    background.source = .image(assetName: assetName)
                    background.treatment.scaleMode = .fitBlur
                }
            }
        }
    }
}

// MARK: - Background controls

struct SceneBackgroundControls: View {
    @EnvironmentObject private var model: AppModel

    @EnvironmentObject private var prefs: PreferencesStore

    @Binding var background: SceneBackground
    /// The scene's layers, so "Lift Subject" can add one.
    var layers: Binding<[SceneLayer]>?
    /// Called with the new subject layer's ID (the composer selects it).
    var onSubjectLifted: ((UUID) -> Void)?

    @Environment(\.composerKind) private var kind
    @State private var importError: String?
    @State private var isLifting = false

    private struct SubjectBox: @unchecked Sendable {
        let result: Result<ImportedSubject, Error>
    }

    enum SourceKind: String, CaseIterable, Identifiable {
        case currentDesktop
        case wallpaper
        case rotatingPool
        case image
        case solid
        case gradient

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .currentDesktop: return "Current Desktop"
            case .wallpaper: return "A Wallpaper"
            case .rotatingPool: return "Rotating"
            case .image: return "An Image"
            case .solid: return "Color"
            case .gradient: return "Gradient"
            }
        }
    }

    private let intervalOptions: [(label: String, value: Double)] = [
        ("30 sec", 30), ("1 min", 60), ("5 min", 300), ("15 min", 900),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ComposerSection(title: "Background") {
                if case .unsupported = background.source {
                    Text("This background was made with a newer version of PaperWalls. Choose another to replace it.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .padding(16)
                    SettingsDivider()
                }
                ComposerRow(title: "Show") {
                    Picker("Background", selection: kindBinding) {
                        ForEach(availableKinds) { kind in
                            Text(kind.displayName).tag(Optional(kind))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                sourceRows
                    .alert("Couldn’t Use Image", isPresented: errorPresented) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(importError ?? "")
                    }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            if usesImage {
                ComposerSection(title: "Treatment") {
                    ComposerRow(title: "Fit") {
                        Picker("Fit", selection: $background.treatment.scaleMode) {
                            ForEach(SceneScaleMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if background.treatment.scaleMode == .fill || background.treatment.scaleMode == .center {
                        SettingsDivider()
                        ComposerSlider(title: "Focus across", value: $background.treatment.focus.x,
                                       lowLabel: "Left", highLabel: "Right")
                        SettingsDivider()
                        ComposerSlider(title: "Focus down", value: $background.treatment.focus.y,
                                       lowLabel: "Top", highLabel: "Bottom")
                        SettingsDivider()
                        ComposerSlider(title: "Zoom", value: $background.treatment.zoom,
                                       range: InteractiveScenePreview.zoomRange, lowLabel: "1×", highLabel: "4×")
                    }
                    SettingsDivider()
                    ComposerSlider(title: "Blur", value: $background.treatment.blur,
                                   lowLabel: "Sharp", highLabel: "Soft")
                    SettingsDivider()
                    ComposerSlider(title: "Dim", value: $background.treatment.dim,
                                   lowLabel: "Bright", highLabel: "Dark")
                    if kind == .screenSaver {
                        SettingsDivider()
                        ComposerRow(title: "Slow zoom") {
                            SettingsToggle(isOn: $background.treatment.slowZoom)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Live backgrounds only make sense for a screen saver.
    private var availableKinds: [SourceKind] {
        switch kind {
        case .screenSaver: return SourceKind.allCases
        case .wallpaper: return [.wallpaper, .image, .solid, .gradient]
        }
    }

    private var usesImage: Bool {
        switch background.source {
        case .currentDesktop, .wallpaper, .rotatingPool, .image: return true
        case .solid, .gradient, .unsupported: return false
        }
    }

    @ViewBuilder
    private var sourceRows: some View {
        switch background.source {
        case .currentDesktop:
            SettingsDivider()
            noteRow("Uses whatever your desktop picture is when the screen saver starts.")
        case .wallpaper(let id):
            SettingsDivider()
            wallpaperPicker(selectedID: id)
        case .rotatingPool(let interval):
            SettingsDivider()
            ComposerRow(title: "Change every") {
                Picker("Change every", selection: intervalBinding(current: interval)) {
                    ForEach(intervalOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
            noteRow(model.rotationPool.isEmpty
                    ? "Your auto-rotate sources are empty right now, so the background will be black. Choose sources in Settings → Auto-Rotate."
                    : "Fades through the \(model.rotationPool.count) wallpapers in your auto-rotate sources (Settings → Auto-Rotate).")
        case .image(let name):
            if !model.allBrandAssets.isEmpty {
                SettingsDivider()
                ComposerRow(title: "Brand Assets") {
                    EmptyView()
                }
                BrandAssetPicker(selectedAssetName: name) { assetName in
                    background.source = .image(assetName: assetName)
                }
            }
            SettingsDivider()
            ComposerRow(title: "Image") {
                HStack(spacing: 8) {
                    if let asset = model.brandAsset(forAssetName: name) {
                        Text(asset.name)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180)
                    } else {
                        Text(name.isEmpty ? "No image chosen" : name)
                            .font(Theme.pathMono)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180)
                    }
                    PhotoLibraryButton(onPicked: importPhoto) {
                        Text("From Photos…")
                    }
                    Button("Choose Image…", action: chooseImage)
                }
            }
            if layers != nil, !name.isEmpty {
                SettingsDivider()
                ComposerRow(title: "Subject") {
                    HStack(spacing: 8) {
                        if isLifting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if hasSubject(from: name) {
                            Text("Lifted into its own layer")
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Lift Subject") {
                                liftSubject(from: name)
                            }
                            .disabled(isLifting)
                            .help("Cut the person, pet, or object in front out of this image and add it as a layer above the clock and text")
                        }
                    }
                }
            }
        case .solid(let colorHex):
            SettingsDivider()
            ComposerColorRow(title: "Color", hex: Binding(get: { colorHex },
                                                         set: { background.source = .solid(colorHex: $0) }))
        case .gradient(let startHex, let endHex, let angle):
            SettingsDivider()
            ComposerColorRow(title: "From", hex: Binding(
                get: { startHex },
                set: { background.source = .gradient(startHex: $0, endHex: endHex, angleDegrees: angle) }))
            SettingsDivider()
            ComposerColorRow(title: "To", hex: Binding(
                get: { endHex },
                set: { background.source = .gradient(startHex: startHex, endHex: $0, angleDegrees: angle) }))
            SettingsDivider()
            ComposerSlider(title: "Direction",
                           value: Binding(
                               get: { angle },
                               set: { background.source = .gradient(startHex: startHex, endHex: endHex, angleDegrees: $0) }),
                           range: 0...360, lowLabel: "0°", highLabel: "360°")
        case .unsupported:
            EmptyView()
        }
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    private func wallpaperPicker(selectedID: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(model.allBrowseWallpapers) { wallpaper in
                    Button {
                        background.source = .wallpaper(id: wallpaper.id)
                    } label: {
                        WallpaperThumbnail(url: model.library.thumbnailURL(for: wallpaper), maxPixelSize: 320)
                            .frame(width: 128, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                    .strokeBorder(wallpaper.id == selectedID ? Theme.accent : Color.clear, lineWidth: 3)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(wallpaper.displayName)
                    .accessibilityLabel(wallpaper.displayName)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(height: 104)
    }

    /// The image is copied into the Studio asset store, so the scene
    /// doesn't depend on where the original file lives.
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            background.source = .image(assetName: try ScreenSaverSceneStore.importAsset(from: url))
        } catch {
            importError = "That file couldn’t be added. Choose a PNG, JPEG, HEIC, TIFF, or GIF image."
        }
    }

    /// Whether a subject layer already came from this image.
    private func hasSubject(from assetName: String) -> Bool {
        layers?.wrappedValue.contains { layer in
            if case .subject(let subject) = layer.content { return subject.sourceAssetName == assetName }
            return false
        } ?? false
    }

    /// Runs the cutout on the background image and adds the subject as
    /// a pinned layer in front of everything. The image is re-imported
    /// through the photo path, so one chosen before this existed (stored
    /// as-is, maybe rotated or huge) gets an upright, size-capped copy
    /// that matches its cutout; the background follows it.
    private func liftSubject(from assetName: String) {
        guard let layers, let url = model.sceneResources.assetURL(assetName),
              let data = try? Data(contentsOf: url) else {
            importError = PhotoImportError.unreadable.localizedDescription
            return
        }
        isLifting = true
        Task {
            let box = await Task.detached(priority: .userInitiated) {
                SubjectBox(result: Result { try SubjectCutout.importSubject(photoData: data) })
            }.value
            isLifting = false
            switch box.result {
            case .success(let imported):
                if imported.photoAssetName != assetName {
                    background.source = .image(assetName: imported.photoAssetName)
                }
                let layer = SceneLayer.subject(imageAssetName: imported.subjectAssetName,
                                               sourceAssetName: imported.photoAssetName,
                                               bounds: imported.bounds)
                layers.wrappedValue.append(layer)
                onSubjectLifted?(layer.id)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    /// A photo from the Photos picker: stored upright, like any other
    /// imported image.
    private func importPhoto(data: Data) {
        do {
            background.source = .image(assetName: try PhotoImporter.importPhoto(data: data).assetName)
        } catch {
            importError = error.localizedDescription
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    // MARK: Bindings

    private var currentKind: SourceKind? {
        switch background.source {
        case .currentDesktop: return .currentDesktop
        case .wallpaper: return .wallpaper
        case .rotatingPool: return .rotatingPool
        case .image: return .image
        case .solid: return .solid
        case .gradient: return .gradient
        case .unsupported: return nil
        }
    }

    /// Switching kind installs that kind's defaults.
    private var kindBinding: Binding<SourceKind?> {
        Binding(
            get: { currentKind },
            set: { newKind in
                guard let newKind, newKind != currentKind else { return }
                switch newKind {
                case .currentDesktop:
                    background.source = .currentDesktop
                case .wallpaper:
                    background.source = .wallpaper(id: model.allBrowseWallpapers.first?.id ?? "")
                case .rotatingPool:
                    background.source = .rotatingPool(intervalSeconds: SceneBackgroundSource.defaultRotationInterval)
                case .image:
                    background.source = .image(assetName: "")
                    // With a generator on offer, let the user pick a path;
                    // otherwise the file chooser is the only one.
                    if !prefs.aiPolicy.offersGeneration {
                        chooseImage()
                    }
                case .solid:
                    background.source = .solid(colorHex: "0B0B0F")
                case .gradient:
                    background.source = .gradient(startHex: "2B1B4A", endHex: "0B1026", angleDegrees: 60)
                }
            })
    }

    /// Snaps an unlisted stored interval to the nearest offered option.
    private func intervalBinding(current: Double) -> Binding<Double> {
        Binding(
            get: {
                intervalOptions.map(\.value).min { abs($0 - current) < abs($1 - current) } ?? current
            },
            set: { background.source = .rotatingPool(intervalSeconds: $0) })
    }
}
