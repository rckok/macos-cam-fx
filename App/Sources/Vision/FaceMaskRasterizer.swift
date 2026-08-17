import CoreGraphics
import Foundation
import Metal

/// Rasterizes face landmark regions into an RGBA8 mask texture:
/// R = left eye, G = right eye, B = mouth (outer lips), A = union of all.
///
/// Polygons are given in vUV space (top-left origin, mirroring applied).
/// CoreGraphics bitmap contexts have a bottom-left origin, so drawing at
/// `y = (1 - v) * height` produces memory in top-to-bottom row order, which is
/// exactly how the texture is sampled.
final class FaceMaskRasterizer {

    struct FaceRegions {
        var leftEye: [CGPoint] = []
        var rightEye: [CGPoint] = []
        var mouth: [CGPoint] = []
    }

    static let width = VirtualCamera.width
    static let height = VirtualCamera.height

    private var context: CGContext?
    private var textures: [MTLTexture] = []
    private var textureIndex = 0

    /// Draws all faces into the mask and returns the uploaded texture.
    /// Runs on the vision queue; textures are triple-buffered so the GPU can
    /// still sample the previously published mask.
    func rasterize(faces: [FaceRegions], device: MTLDevice) -> MTLTexture? {
        guard let context = ensureContext() else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        for face in faces {
            fill(face.leftEye, red: 1, green: 0, blue: 0, in: context)
            fill(face.rightEye, red: 0, green: 1, blue: 0, in: context)
            fill(face.mouth, red: 0, green: 0, blue: 1, in: context)
        }

        guard let texture = nextTexture(device: device), let data = context.data else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, Self.width, Self.height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: context.bytesPerRow
        )
        return texture
    }

    private func fill(_ polygon: [CGPoint], red: CGFloat, green: CGFloat, blue: CGFloat, in context: CGContext) {
        guard polygon.count >= 3 else { return }
        let path = CGMutablePath()
        let points = polygon.map { point in
            CGPoint(x: point.x * CGFloat(Self.width), y: (1 - point.y) * CGFloat(Self.height))
        }
        path.addLines(between: points)
        path.closeSubpath()
        // Opaque fills: each region writes its channel and saturates alpha,
        // so A naturally becomes the union of all regions.
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.addPath(path)
        context.fillPath()
    }

    private func ensureContext() -> CGContext? {
        if let context { return context }
        let context = CGContext(
            data: nil,
            width: Self.width,
            height: Self.height,
            bitsPerComponent: 8,
            bytesPerRow: Self.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setAllowsAntialiasing(true)
        self.context = context
        return context
    }

    private func nextTexture(device: MTLDevice) -> MTLTexture? {
        if textures.isEmpty {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: Self.width, height: Self.height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            textures = (0..<3).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            guard textures.count == 3 else {
                textures = []
                return nil
            }
        }
        let texture = textures[textureIndex]
        textureIndex = (textureIndex + 1) % textures.count
        return texture
    }
}
