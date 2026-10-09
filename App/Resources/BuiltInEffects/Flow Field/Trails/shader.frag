// Feedback: last frame's trails, faded, plus this frame's particles.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=0.999 default=0.99)
    float trail_length;
    // @metadata(min=0.0 max=32.0 default=16.0 global)
    float trail_blur;
    // @metadata(min=0.0 max=1.0 default=0.9 global)
    float trail_decay;
};

void main() {
    // The small subtraction lets faint trails reach black despite 8-bit
    // rounding, which would otherwise hold them at a low glow forever.
    vec3 trail = max(ceDiscBlurArray(uStageTextures, vUV, uStageIndex, trail_blur, 8, 1.0).rgb * trail_length - 1.5 / 255.0, 0.0);
    vec3 particles = ceStageTexture("Particles", vUV).rgb;
    outColor = vec4(max(trail * trail_decay, particles), 1.0);
}
