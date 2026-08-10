import MetalKit
import SwiftUI

/// Realtime preview of the render engine's latest output texture,
/// letterboxed to preserve aspect ratio.
struct PreviewView: NSViewRepresentable {
    let engine: RenderEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: engine.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        private let engine: RenderEngine
        private let commandQueue: MTLCommandQueue

        init(engine: RenderEngine) {
            self.engine = engine
            self.commandQueue = engine.device.makeCommandQueue()!
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let texture = engine.previewTexture,
                  let drawable = view.currentDrawable,
                  let passDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

            // Aspect-fit viewport.
            let drawableWidth = Double(drawable.texture.width)
            let drawableHeight = Double(drawable.texture.height)
            let textureAspect = Double(texture.width) / Double(texture.height)
            let drawableAspect = drawableWidth / drawableHeight

            var viewport = MTLViewport(
                originX: 0, originY: 0,
                width: drawableWidth, height: drawableHeight,
                znear: 0, zfar: 1
            )
            if textureAspect > drawableAspect {
                let height = drawableWidth / textureAspect
                viewport.originY = (drawableHeight - height) / 2
                viewport.height = height
            } else {
                let width = drawableHeight * textureAspect
                viewport.originX = (drawableWidth - width) / 2
                viewport.width = width
            }
            encoder.setViewport(viewport)

            engine.encodePreviewBlit(texture: texture, encoder: encoder)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
