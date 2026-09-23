import AppKit
import Foundation
import ImageIO
import Metal

/// One image in the background gallery.
struct BackgroundImage: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    /// Filename inside the Backgrounds directory, e.g. `A1B2C3.jpg`.
    let fileName: String
}

/// On-disk catalog of the background gallery.
private struct BackgroundLibraryManifest: Codable {
    var images: [BackgroundImage] = []
}

/// The images the camera view can put behind the person. Kept apart from the
/// shader media library: deleting a background must never unbind a stage's
/// sampler, and the gallery should only ever show backgrounds.
@MainActor
final class BackgroundLibrary: ObservableObject {

    @Published private(set) var images: [BackgroundImage] = []

    private let imagesURL: URL
    private let manifestURL: URL
    /// Full-size GPU textures, by image ID. Only the selected background is
    /// ever loaded, so this rarely holds more than one entry.
    private var textures: [String: MTLTexture] = [:]
    /// Downsampled previews for the gallery cells.
    private var thumbnails: [String: NSImage] = [:]

    nonisolated static let thumbnailMaxPixelSize = 256

    init(appSupportRoot: URL) {
        imagesURL = appSupportRoot.appendingPathComponent("Backgrounds", isDirectory: true)
        manifestURL = appSupportRoot.appendingPathComponent("backgrounds.json")
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        load()
    }

    func fileURL(for image: BackgroundImage) -> URL {
        imagesURL.appendingPathComponent(image.fileName)
    }

    func image(id: String) -> BackgroundImage? {
        images.first { $0.id == id }
    }

    @discardableResult
    func add(from sourceURL: URL) throws -> BackgroundImage {
        let id = UUID().uuidString
        let ext = sourceURL.pathExtension.isEmpty ? "dat" : sourceURL.pathExtension
        let fileName = "\(id).\(ext)"
        let destinationURL = imagesURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let image = BackgroundImage(
            id: id,
            name: sourceURL.deletingPathExtension().lastPathComponent,
            fileName: fileName
        )
        images.append(image)
        save()
        preloadThumbnails(for: [image])
        return image
    }

    func remove(id: String) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: images[index]))
        images.remove(at: index)
        textures.removeValue(forKey: id)
        thumbnails.removeValue(forKey: id)
        save()
    }

    // MARK: GPU textures and thumbnails

    /// The full-size texture of `id`, loaded on first use.
    func texture(for id: String, device: MTLDevice) -> MTLTexture? {
        if let cached = textures[id] { return cached }
        guard let image = image(id: id),
              let texture = ImageTextureLoader.load(url: fileURL(for: image), device: device)
        else { return nil }
        textures[id] = texture
        return texture
    }

    /// A preview no larger than `thumbnailMaxPixelSize` on its long side.
    /// Decoding happens off the main thread; this only returns one that is
    /// already ready, so opening the gallery never stalls the preview.
    func thumbnail(for id: String) -> NSImage? {
        thumbnails[id]
    }

    // MARK: Private

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackgroundLibraryManifest.self, from: data)
        else { return }
        images = manifest.images.filter {
            FileManager.default.fileExists(atPath: imagesURL.appendingPathComponent($0.fileName).path)
        }
        preloadThumbnails(for: images)
    }

    /// ImageIO on a background queue. The gallery reads `thumbnails` on the
    /// main thread, so the decode must not happen there: a handful of source
    /// photos is enough to freeze the camera preview for a noticeable beat.
    private func preloadThumbnails(for images: [BackgroundImage]) {
        let jobs = images.map { (id: $0.id, url: fileURL(for: $0)) }
        let maxPixelSize = Self.thumbnailMaxPixelSize
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let decoded = jobs.compactMap { job -> (String, CGImage)? in
                Self.decodeThumbnail(at: job.url, maxPixelSize: maxPixelSize).map { (job.id, $0) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var changed = false
                for (id, cgImage) in decoded where self.thumbnails[id] == nil {
                    self.thumbnails[id] = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                    changed = true
                }
                if changed { self.objectWillChange.send() }
            }
        }
    }

    private nonisolated static func decodeThumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func save() {
        let manifest = BackgroundLibraryManifest(images: images)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: manifestURL)
        }
    }
}
