// Stage 2 of the "Ghost Aberration" effect: pulls the color channels apart
// along a slowly rotating axis. `split` is global; `speed` stays a stage-only
// control you can only reach in Editor Mode.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=1.0 default=0.35 global)
    float split;
    // @metadata(min=0.0 max=2.0 default=0.4)
    float speed;
};

void main() {
    float angle = uTime * speed;
    vec2 shift = vec2(cos(angle), sin(angle)) * split * 0.02;
    vec4 base = texture(uPrev, vUV);

    outColor = vec4(
        texture(uPrev, vUV + shift).r,
        base.g,
        texture(uPrev, vUV - shift).b,
        base.a
    );
}
