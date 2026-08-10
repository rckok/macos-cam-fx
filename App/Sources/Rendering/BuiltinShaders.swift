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
    """
}
