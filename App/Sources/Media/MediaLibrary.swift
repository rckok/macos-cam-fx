import Foundation
import Metal
import UniformTypeIdentifiers

/// A single image or video stored in the app's shared media library.
struct MediaAsset: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case image
        case video
    }

    let id: String
    var name: String
    /// Filename inside the Media directory, e.g. `A1B2C3.png`.
    let fileName: String
    let kind: Kind

    var displayName: String { name }
}

/// On-disk catalog for the shared media library.
private struct MediaLibraryManifest: Codable {
    var assets: [MediaAsset] = []
}

/// Shared media library: images and videos available to any effect shader.
@MainActor
final class MediaLibrary: ObservableObject {

    @Published private(set) var assets: [MediaAsset] = []
    private(set) var textureCache: MediaTextureCache?

    private let mediaURL: URL
    private let manifestURL: URL

    static let imageContentTypes: [UTType] = [
        .png, .jpeg, .tiff, .gif, .bmp, .heic, .webP,
    ]

    static let videoContentTypes: [UTType] = [
        .movie, .mpeg4Movie, .quickTimeMovie, .avi, .video,
    ]

    static func isVideoURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return videoContentTypes.contains { type.conforms(to: $0) }
    }

    init(appSupportRoot: URL) {
        mediaURL = appSupportRoot.appendingPathComponent("Media", isDirectory: true)
        manifestURL = appSupportRoot.appendingPathComponent("media-library.json")
        try? FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        load()
    }

    func fileURL(for asset: MediaAsset) -> URL {
        mediaURL.appendingPathComponent(asset.fileName)
    }

    func asset(id: String) -> MediaAsset? {
        assets.first { $0.id == id }
    }

    func reloadGPUCache(device: MTLDevice) {
        textureCache = MediaTextureCache(device: device, assets: assets, mediaFolderURL: mediaURL)
    }

    @discardableResult
    func addAsset(from sourceURL: URL) throws -> MediaAsset {
        let id = UUID().uuidString
        let kind: MediaAsset.Kind = Self.isVideoURL(sourceURL) ? .video : .image
        let ext = sourceURL.pathExtension.isEmpty ? "dat" : sourceURL.pathExtension
        let fileName = "\(id).\(ext)"
        let destinationURL = mediaURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let asset = MediaAsset(
            id: id,
            name: sourceURL.deletingPathExtension().lastPathComponent,
            fileName: fileName,
            kind: kind
        )
        assets.append(asset)
        save()
        return asset
    }

    func removeAsset(id: String) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        let asset = assets[index]
        try? FileManager.default.removeItem(at: fileURL(for: asset))
        assets.remove(at: index)
        save()
        textureCache?.unload(mediaID: id)
    }

    // MARK: Private

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(MediaLibraryManifest.self, from: data)
        else { return }
        assets = manifest.assets.filter {
            FileManager.default.fileExists(atPath: mediaURL.appendingPathComponent($0.fileName).path)
        }
    }

    private func save() {
        let manifest = MediaLibraryManifest(assets: assets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: manifestURL)
        }
    }
}
