import AppKit
import AVFoundation
import CoreVideo
import Foundation
import Metal
import MetalKit
import os.log

private let textureLogger = Logger(subsystem: "studio.polyglot.CameraEffects", category: "media-texture")

/// GPU textures for media-library assets, shared across all effects.
final class MediaTextureCache {
    private let device: MTLDevice
    private let assetIndex: [String: (url: URL, kind: MediaAsset.Kind)]
    private let lock = NSLock()
    private var images: [String: MTLTexture] = [:]
    private var videos: [String: VideoTextureSource] = [:]

    init(device: MTLDevice, assets: [MediaAsset], mediaFolderURL: URL) {
        self.device = device
        self.assetIndex = Dictionary(
            uniqueKeysWithValues: assets.map {
                ($0.id, (mediaFolderURL.appendingPathComponent($0.fileName), $0.kind))
            }
        )
    }

    func texture(forMediaID id: String) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = images[id] { return cached }
        if let video = videos[id] { return video.texture }

        guard let entry = assetIndex[id] else { return nil }

        switch entry.kind {
        case .image:
            guard let texture = Self.loadImage(url: entry.url, device: device) else { return nil }
            images[id] = texture
            return texture
        case .video:
            guard let source = VideoTextureSource(url: entry.url, device: device) else { return nil }
            videos[id] = source
            return source.texture
        }
    }

    func advanceVideoFrames() {
        lock.lock()
        let sources = Array(videos.values)
        lock.unlock()
        for source in sources {
            source.updateFrame()
        }
    }

    func unload(mediaID: String) {
        lock.lock()
        images.removeValue(forKey: mediaID)
        videos.removeValue(forKey: mediaID)
        lock.unlock()
    }

    func reload(mediaID: String) {
        unload(mediaID: mediaID)
        _ = texture(forMediaID: mediaID)
    }

    private static func loadImage(url: URL, device: MTLDevice) -> MTLTexture? {
        if let texture = loadImageWithMTKTextureLoader(url: url, device: device) {
            return texture
        }
        if let texture = loadImageWithBitmapRep(url: url, device: device) {
            textureLogger.info("Loaded image via bitmap fallback: \(url.lastPathComponent, privacy: .public)")
            return texture
        }
        textureLogger.error("Failed to load image texture: \(url.path, privacy: .public)")
        return nil
    }

    private static func loadImageWithMTKTextureLoader(url: URL, device: MTLDevice) -> MTLTexture? {
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .SRGB: false,
        ]
        return try? loader.newTexture(URL: url, options: options)
    }

    /// Fallback for PNGs MTKTextureLoader cannot decode (e.g. 8-bit indexed/colormap).
    private static func loadImageWithBitmapRep(url: URL, device: MTLDevice) -> MTLTexture? {
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data),
              let bitmapData = rep.bitmapData
        else { return nil }

        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return nil }

        let samplesPerPixel = rep.samplesPerPixel
        guard samplesPerPixel == 3 || samplesPerPixel == 4 else { return nil }

        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 255, count: height * bytesPerRow)
        let sourceBytesPerRow = rep.bytesPerRow

        for y in 0..<height {
            for x in 0..<width {
                let sourceIndex = y * sourceBytesPerRow + x * samplesPerPixel
                let destinationIndex = y * bytesPerRow + x * 4
                rgba[destinationIndex] = bitmapData[sourceIndex]
                rgba[destinationIndex + 1] = bitmapData[sourceIndex + 1]
                rgba[destinationIndex + 2] = bitmapData[sourceIndex + 2]
                rgba[destinationIndex + 3] = samplesPerPixel == 4 ? bitmapData[sourceIndex + 3] : 255
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        rgba.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }
}

// MARK: - Looping video frame source

private final class VideoTextureSource {
    private let player: AVPlayer
    private let videoOutput: AVPlayerItemVideoOutput
    private let textureCache: CVMetalTextureCache
    private var loopObserver: NSObjectProtocol?

    private let lock = NSLock()
    private var currentTexture: MTLTexture?

    init?(url: URL, device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else { return nil }
        textureCache = cache

        let item = AVPlayerItem(url: url)
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelAttributes)
        item.add(videoOutput)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        DispatchQueue.main.async { [player] in
            player.play()
        }
    }

    deinit {
        player.pause()
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
    }

    var texture: MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return currentTexture
    }

    func updateFrame() {
        guard let item = player.currentItem else { return }
        let time = item.currentTime()
        guard videoOutput.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTexture)
        else { return }

        lock.lock()
        currentTexture = metalTexture
        lock.unlock()
    }
}
