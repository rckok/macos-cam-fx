import MetalKit
import SwiftUI

/// Realtime preview of the render engine's latest output texture. `.fit`
/// letterboxes to preserve aspect ratio; `.fill` covers the view and crops.
struct PreviewView: NSViewRepresentable {
    let engine: RenderEngine
    var contentMode: ContentMode = .fit

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
        // Until the first drawable is presented the layer is empty, and the
        // window behind it is white. Black matches the empty preview.
        view.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.contentMode = contentMode
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let engine: RenderEngine
        private let commandQueue: MTLCommandQueue
        /// Read on the MTKView's draw callback, written from SwiftUI updates;
        /// both happen on the main thread.
        var contentMode: ContentMode = .fit

        init(engine: RenderEngine) {
            self.engine = engine
            self.commandQueue = engine.device.makeCommandQueue()!
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let passDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            // No camera image — a suspended device, or nothing captured yet.
            // Clearing without presenting leaves the window's white background
            // showing through, which hides the light controls.
            guard let texture = engine.previewTexture else {
                passDescriptor.colorAttachments[0].loadAction = .clear
                passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)?.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

            // The viewport is the frame's rectangle centered on the drawable:
            // inside it for .fit (letterboxed), spilling past its edges for
            // .fill (cropped). Metal clips whatever falls outside the drawable.
            let drawableWidth = Double(drawable.texture.width)
            let drawableHeight = Double(drawable.texture.height)
            let textureAspect = Double(texture.width) / Double(texture.height)
            let drawableAspect = drawableWidth / drawableHeight
            let fitWidth = textureAspect > drawableAspect ? contentMode == .fit : contentMode == .fill

            var viewport = MTLViewport(
                originX: 0, originY: 0,
                width: drawableWidth, height: drawableHeight,
                znear: 0, zfar: 1
            )
            if fitWidth {
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
