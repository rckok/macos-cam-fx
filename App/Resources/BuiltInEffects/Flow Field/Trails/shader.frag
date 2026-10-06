// Feedback: last frame's trails, faded, plus this frame's particles.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=0.99 default=0.9 global)
    float trailLength;
};

void main() {
    // The small subtraction lets faint trails reach black despite 8-bit
    // rounding, which would otherwise hold them at a low glow forever.
    vec3 trail = max(ceSelfTexture(vUV).rgb * trailLength - 1.5 / 255.0, 0.0);
    vec3 particles = ceStageTexture("Particles", vUV).rgb;
    outColor = vec4(trail + particles, 1.0);
}
