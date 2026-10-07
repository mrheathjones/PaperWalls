import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

// Photos → Studio. Two steps, both done in the app so the saver never
// needs the Photos library or Vision:
//
//   1. `PhotoImporter` turns picked image bytes into an asset-store file
//      plus an upright, size-capped CGImage of it.
//   2. `SubjectCutout` lifts the photo's foreground with Vision and
//      writes it as a PNG with transparency, the same pixel size as the
//      stored photo — so a pinned subject lands exactly on it.
//
// `PhotoLibraryButton` is the system Photos picker: it runs out of
// process and hands over only the chosen images, so the app needs no
// Photos permission and managed Macs need no PPPC profile.

/// A photo copied into the Studio asset store.
struct ImportedPhoto {
    /// Asset-store name of the file the scene will reference.
    let assetName: String
    /// The stored photo, upright, decoded (what the cutout is made from).
    let image: CGImage
}

/// A subject cutout in the asset store, with the photo it came from and
/// where in it the subject sits.
struct ImportedSubject: Equatable {
    let subjectAssetName: String
    let photoAssetName: String
    let bounds: SceneRect
}

enum PhotoImportError: LocalizedError {
    case unreadable
    case noSubject
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "That image couldn’t be read. Choose a PNG, JPEG, HEIC, TIFF, or GIF image."
        case .noSubject:
            return "No clear subject was found in that photo. Try one with a person, pet, or object that stands out from the background."
        case .encodingFailed:
            return "The cutout couldn’t be saved."
        }
    }
}

enum PhotoImporter {
    /// Long-edge cap, in pixels, for a photo that will be cut out. Larger
    /// photos are stored at this size so the photo and its cutout always
    /// match pixel for pixel (and a 48 MP shot doesn't become a 100 MB
    /// PNG). It is over 5K, so nothing a display can show is lost.
    static let maxPixelSize = 6144

    /// Copies a photo into the asset store. The original bytes are kept
    /// when they are already upright, within the size cap and in a
    /// format the store accepts; otherwise the upright, capped image is
    /// re-encoded (JPEG, or PNG when it has transparency).
    static func importPhoto(data: Data) throws -> ImportedPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw PhotoImportError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let image = try uprightImage(from: source)

        let typeIdentifier = CGImageSourceGetType(source) as String?
        let fileExtension = typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension }
        let keepsOriginal = orientation == 1 && max(width, height) <= maxPixelSize
        if keepsOriginal, let fileExtension,
           ScreenSaverSceneStore.assetName(forData: data, fileExtension: fileExtension) != nil {
            return ImportedPhoto(assetName: try ScreenSaverSceneStore.importAsset(data: data, fileExtension: fileExtension),
                                 image: image)
        }
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        let encoded = try encode(image, as: hasAlpha ? .png : .jpeg)
        return ImportedPhoto(assetName: try ScreenSaverSceneStore.importAsset(data: encoded, fileExtension: hasAlpha ? "png" : "jpg"),
                             image: image)
    }

    static func importPhoto(url: URL) throws -> ImportedPhoto {
        try importPhoto(data: try Data(contentsOf: url))
    }

    /// The first frame, rotated upright per its EXIF orientation and no
    /// larger than `maxPixelSize` on its long edge — never upscaled.
    static func uprightImage(from source: CGImageSource) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoImportError.unreadable
        }
        return image
    }

    static func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw PhotoImportError.encodingFailed
        }
        let properties: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoImportError.encodingFailed
        }
        return data as Data
    }
}

enum SubjectCutout {
    /// Soft edge, in pixels, applied to Vision's mask — hides the halo a
    /// hard mask leaves around hair and foliage.
    static let featherRadius: Double = 1.5

    /// The photo's foreground on a transparent background, as PNG bytes
    /// the same pixel size as `image`, plus the subject's bounds in it.
    /// Throws `noSubject` when Vision finds nothing that stands out.
    static func cutout(subjectOf image: CGImage) throws -> (png: Data, bounds: SceneRect) {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw PhotoImportError.noSubject
        }
        let maskBuffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances,
                                                                    from: handler)
        let bounds = try subjectBounds(in: maskBuffer)
        let photo = CIImage(cgImage: image)
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        // Vision's mask is scaled to the image, but rounding can leave it
        // a pixel off — stretch it to the photo exactly.
        if mask.extent.size != photo.extent.size, mask.extent.width > 0, mask.extent.height > 0 {
            mask = mask.transformed(by: CGAffineTransform(scaleX: photo.extent.width / mask.extent.width,
                                                          y: photo.extent.height / mask.extent.height))
        }
        if featherRadius > 0 {
            mask = mask.clampedToExtent()
                .applyingGaussianBlur(sigma: featherRadius)
                .cropped(to: photo.extent)
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = photo
        blend.backgroundImage = CIImage(color: .clear).cropped(to: photo.extent)
        blend.maskImage = mask
        guard let output = blend.outputImage?.cropped(to: photo.extent) else {
            throw PhotoImportError.encodingFailed
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let png = context.pngRepresentation(of: output, format: .RGBA8, colorSpace: colorSpace, options: [:]) else {
            throw PhotoImportError.encodingFailed
        }
        return (png, bounds)
    }

    /// The box around every mask pixel that is more than half on, as a
    /// unit rect with a top-left origin (the mask buffer's own row
    /// order), padded by one pixel so a feathered edge isn't clipped.
    static func subjectBounds(in mask: CVPixelBuffer) throws -> SceneRect {
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float else {
            throw PhotoImportError.encodingFailed
        }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { throw PhotoImportError.encodingFailed }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask) / MemoryLayout<Float>.size
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = base.advanced(by: y * stride * MemoryLayout<Float>.size).assumingMemoryBound(to: Float.self)
            var x = 0
            while x < width {
                if row[x] > 0.5 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    maxY = y
                }
                x += 1
            }
        }
        guard maxX >= minX, maxY >= minY, width > 0, height > 0 else { throw PhotoImportError.noSubject }
        let pad = 2
        let x0 = max(0, minX - pad), y0 = max(0, minY - pad)
        let x1 = min(width, maxX + 1 + pad), y1 = min(height, maxY + 1 + pad)
        return SceneRect(x: Double(x0) / Double(width), y: Double(y0) / Double(height),
                         width: Double(x1 - x0) / Double(width), height: Double(y1 - y0) / Double(height))
    }

    /// Imports the photo and its cutout into the asset store. Heavy
    /// (Vision + a full-size PNG encode): call off the main thread.
    static func importSubject(photoData: Data) throws -> ImportedSubject {
        let photo = try PhotoImporter.importPhoto(data: photoData)
        let cut = try cutout(subjectOf: photo.image)
        let name = try ScreenSaverSceneStore.importAsset(data: cut.png, fileExtension: "png")
        return ImportedSubject(subjectAssetName: name, photoAssetName: photo.assetName, bounds: cut.bounds)
    }
}

// MARK: - Pickers

/// The system Photos picker as a button. Delivers the chosen image's
/// bytes; the app never sees the rest of the library.
struct PhotoLibraryButton<Label: View>: View {
    let onPicked: (Data) -> Void
    @ViewBuilder let label: () -> Label

    @State private var selection: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
            label()
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            selection = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    onPicked(data)
                }
            }
        }
    }
}

enum ImageFilePicker {
    /// The standard open panel, limited to images. Its sidebar also
    /// offers Media › Photos, so the library is reachable here too.
    @MainActor
    static func chooseImageFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
