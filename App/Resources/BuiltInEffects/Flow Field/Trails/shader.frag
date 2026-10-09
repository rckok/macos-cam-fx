// Feedback: last frame's trails, faded, plus this frame's particles.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=0.999 default=0.99)
    float trail_length;
    // @metadata(min=0.0 max=32.0 default=16.0 global)
    float trail_blur;
    // @metadata(min=0.0 max=1.0 default=0.9 global)
    float trail_decay;
};

// Interleaved gradient noise (Jimenez 2014): cheap, stable per-pixel [0,1).
float noiseIGN(vec2 px) {
    return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));
}

// Single-pass disc blur. `radius` in pixels, `taps` = quality (16–32 is plenty).
// falloff = 0.0 → flat disc (bokeh); 1.0 → soft, roughly Gaussian look.
vec4 blurSelfTexture(vec2 uv, float radius, int taps, float falloff) {
    const float GOLDEN_ANGLE = 2.39996323;
    float rotation = noiseIGN(vUV * uResolution) * 6.28318531;
    vec2 scale = radius / uResolution;
    vec4 sum = vec4(0.0);
    float total = 0.0;
    for (int i = 0; i < 64; i++) {
        if (i >= taps) { break; }
        float r = sqrt((float(i) + 0.5) / float(taps));    // uniform area coverage
        float a = float(i) * GOLDEN_ANGLE + rotation;
        float w = 1.0 - falloff * r * r;
        sum += ceSelfTexture(uv + vec2(cos(a), sin(a)) * r * scale) * w;
        total += w;
    }
    return sum / total;
}

void main() {
    // The small subtraction lets faint trails reach black despite 8-bit
    // rounding, which would otherwise hold them at a low glow forever.
//    vec3 trail = max(blurSelfTexture(vUV, trail_blur, 8, 1.0).rgb * trail_length - 1.5 / 255.0, 0.0);
    vec3 trail = max(ceDiscBlur3D(uStageTextures, vUV, uStageIndex, trail_blur, 8, 1.0).rgb * trail_length - 1.5 / 255.0, 0.0);
    vec3 particles = ceStageTexture("Particles", vUV).rgb;
    outColor = vec4(max(trail * trail_decay, particles), 1.0);
}
