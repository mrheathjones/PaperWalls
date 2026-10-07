import AppKit
import SwiftUI

/// "Add a subject from a photo": pick a photo (Photos library or a
/// file), Vision lifts its foreground, and the result comes back as two
/// asset-store files — the photo and the cutout. Used from Add Layer and
/// from a subject layer's Replace button.
struct SubjectImportSheet: View {
    /// Replacing an existing layer's subject, rather than adding one.
    var isReplacing = false
    /// The chosen files, and whether the photo should become the
    /// background (the iOS lock-screen setup: the clock sits between the
    /// photo and its own subject).
    let onImported: (ImportedSubject, _ usePhotoAsBackground: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var usesPhotoAsBackground = true
    @State private var isWorking = false
    @State private var errorMessage: String?

    private struct SubjectBox: @unchecked Sendable {
        let result: Result<ImportedSubject, Error>
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isReplacing ? "Replace the Subject" : "Add a Subject from a Photo")
                .font(.system(size: 18, weight: .semibold))
            Text("The person, pet, or object in front is lifted out of the photo and becomes its own layer. Put it above the clock, and the clock shows through behind it — like the iPhone lock screen.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                PhotoLibraryButton(onPicked: process) {
                    Label("From Photos…", systemImage: "photo.on.rectangle")
                }
                Button {
                    guard let url = ImageFilePicker.chooseImageFile() else { return }
                    process(url: url)
                } label: {
                    Label("Choose File…", systemImage: "folder")
                }
            }
            .disabled(isWorking)

            Toggle("Use the photo as the background", isOn: $usesPhotoAsBackground)
                .toggleStyle(.checkbox)
                .disabled(isWorking)

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding the subject…")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func process(url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = PhotoImportError.unreadable.localizedDescription
            return
        }
        process(data: data)
    }

    private func process(data: Data) {
        isWorking = true
        errorMessage = nil
        let usesPhotoAsBackground = usesPhotoAsBackground
        Task {
            let box = await Task.detached(priority: .userInitiated) {
                SubjectBox(result: Result { try SubjectCutout.importSubject(photoData: data) })
            }.value
            isWorking = false
            switch box.result {
            case .success(let imported):
                onImported(imported, usesPhotoAsBackground)
                dismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// The Subject card: a look at the cutout, pin/unpin, swap the photo in
/// as the background, replace the subject, shadow.
struct SubjectLayerControls: View {
    @EnvironmentObject private var model: AppModel

    @Binding var subject: SubjectLayer
    /// The scene's background, for "Use Photo as Background".
    var background: Binding<SceneBackground>?

    @State private var isReplacing = false

    var body: some View {
        ComposerSection(title: "Subject") {
            HStack(alignment: .top, spacing: 14) {
                SubjectThumbnail(url: model.sceneResources.assetURL(subject.imageAssetName))
                    .frame(width: 120, height: 90)
                VStack(alignment: .leading, spacing: 6) {
                    Text(subject.isPinned ? "Pinned to the photo" : "Free layer")
                        .font(.system(size: 14, weight: .medium))
                    Text(subject.isPinned
                         ? "Sits exactly where it was in the photo and follows the background’s fit, focus, and zoom. Layers below it in the list show through behind it."
                         : "Moves, resizes, and animates like any other layer — for standing the subject in front of a different background.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            SettingsDivider()
            ComposerRow(title: "Pin to photo") {
                SettingsToggle(isOn: $subject.isPinned)
            }
            if let background, let photo = subject.sourceAssetName {
                SettingsDivider()
                ComposerRow(title: "Background") {
                    Button("Use Photo as Background") {
                        background.wrappedValue.source = .image(assetName: photo)
                        background.wrappedValue.treatment.scaleMode = .fill
                        background.wrappedValue.treatment.zoom = 1
                        background.wrappedValue.treatment.focus = .center
                    }
                    .disabled(background.wrappedValue.source == .image(assetName: photo))
                    .help("Put the photo this subject came from behind everything, so the subject lands back on it")
                }
            }
            SettingsDivider()
            ComposerRow(title: "Photo") {
                Button("Replace Subject…") {
                    isReplacing = true
                }
            }
            SettingsDivider()
            ComposerRow(title: "Shadow") {
                SettingsToggle(isOn: $subject.shadow)
            }
        }
        .sheet(isPresented: $isReplacing) {
            SubjectImportSheet(isReplacing: true) { imported, usePhotoAsBackground in
                // One write: the binding into the layer's content hands
                // back a snapshot, so field-by-field writes would each
                // start from the old value and keep only the last.
                var replaced = subject
                replaced.imageAssetName = imported.subjectAssetName
                replaced.sourceAssetName = imported.photoAssetName
                replaced.bounds = imported.bounds
                subject = replaced
                if usePhotoAsBackground, let background {
                    background.wrappedValue.source = .image(assetName: imported.photoAssetName)
                    background.wrappedValue.treatment.scaleMode = .fill
                    background.wrappedValue.treatment.zoom = 1
                    background.wrappedValue.treatment.focus = .center
                }
            }
        }
    }
}

/// The cutout on a neutral tile, so its transparent edge is visible.
private struct SubjectThumbnail: View {
    let url: URL?

    @State private var image: NSImage?

    private struct ImageBox: @unchecked Sendable {
        let image: NSImage?
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.chipFill)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            let box = await Task.detached(priority: .utility) { () -> ImageBox in
                guard let cgImage = SceneImageLoader.downsampledImage(at: url, maxPixelSize: 480) else {
                    return ImageBox(image: nil)
                }
                return ImageBox(image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
            }.value
            image = box.image
        }
    }
}
