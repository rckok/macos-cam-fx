import Foundation

/// Native MSL shaders used by the render pipeline itself (not user effects).
enum BuiltinShaders {
    /// Fullscreen-triangle vertex shader. Outputs UV with a top-left origin so
    /// it matches video pixel-buffer row order, and declares the varying at
    /// `[[user(locn0)]]` to match SPIRV-Cross's fragment input for
    /// `layout(location = 0) in vec2 vUV`.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CEVertexOut {
        float4 position [[position]];
        float2 uv [[user(locn0)]];
    };

    vertex CEVertexOut ce_fullscreen_vertex(uint vid [[vertex_id]]) {
        const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        CEVertexOut out;
        float2 p = positions[vid];
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
        return out;
    }

    fragment float4 ce_blit_fragment(CEVertexOut in [[stage_in]],
                                     texture2d<float> source [[texture(0)]],
                                     sampler smp [[sampler(0)]]) {
        return source.sample(smp, in.uv);
    }

    /// Horizontal mirror used for the mirror-front-camera setting.
    fragment float4 ce_blit_flip_h_fragment(CEVertexOut in [[stage_in]],
                                           texture2d<float> source [[texture(0)]],
                                           sampler smp [[sampler(0)]]) {
        float2 uv = float2(1.0 - in.uv.x, in.uv.y);
        return source.sample(smp, uv);
    }

    /// Background replacement: the selected image under the camera frame,
    /// masked by the person matte. Runs in place of the scale/mirror blit, so
    /// the camera and the raw Vision matte share the (optionally mirrored)
    /// camera UV, while the background keeps its own orientation and is
    /// aspect-filled through `backgroundUV` (xy = scale, zw = offset).
    struct CEBackgroundUniforms {
        float4 backgroundUV;
        float mirror;
    };

    fragment float4 ce_background_composite_fragment(CEVertexOut in [[stage_in]],
                                                     texture2d<float> camera [[texture(0)]],
                                                     texture2d<float> background [[texture(1)]],
                                                     texture2d<float> matte [[texture(2)]],
                                                     sampler smp [[sampler(0)]],
                                                     constant CEBackgroundUniforms& uniforms [[buffer(0)]]) {
        float2 cameraUV = float2(mix(in.uv.x, 1.0 - in.uv.x, uniforms.mirror), in.uv.y);
        float2 backgroundUV = in.uv * uniforms.backgroundUV.xy + uniforms.backgroundUV.zw;
        float4 frame = camera.sample(smp, cameraUV);
        float4 image = background.sample(smp, backgroundUV);
        float person = smoothstep(0.35, 0.65, matte.sample(smp, cameraUV).r);
        return float4(mix(image.rgb, frame.rgb, person), 1.0);
    }

    /// Approximate hand silhouette: max coverage over capsules placed along
    /// the detected hand skeleton (see HandMaskRenderer). Layout must match
    /// HandMaskRenderer.uniformSlots: one header slot, then `maxCapsules`
    /// segment slots, then `maxCapsules` radius slots.
    struct CEHandMaskUniforms {
        float4 header;        // xy = target size in pixels, z = capsule count
        float4 segments[64];  // xy = start, zw = end (pixels)
        float4 radii[64];     // x = start radius, y = end radius (pixels)
    };

    fragment float4 ce_hand_mask_fragment(CEVertexOut in [[stage_in]],
                                          constant CEHandMaskUniforms& hands [[buffer(0)]]) {
        float2 p = in.uv * hands.header.xy;
        int count = int(hands.header.z);
        float coverage = 0.0;
        for (int i = 0; i < count; ++i) {
            float2 a = hands.segments[i].xy;
            float2 ba = hands.segments[i].zw - a;
            float2 pa = p - a;
            float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
            float dist = length(pa - ba * h);
            float ra = hands.radii[i].x;
            float rb = hands.radii[i].y;
            float r = mix(ra, rb > 0.0 ? rb : ra, h);
            // 2 px feathered edge around the capsule boundary.
            coverage = max(coverage, saturate((r - dist) * 0.5 + 0.5));
        }
        return float4(coverage, coverage, coverage, coverage);
    }
    """
}
