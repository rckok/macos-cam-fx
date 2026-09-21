// Stage 1 of the "Ghost Aberration" effect: blends the live frame with a
// decaying echo of the last few frames. `ghosting` is marked global, so it
// also shows up on the effect itself and stays reachable in Basic Mode.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=1.0 default=0.6 global)
    float ghosting;
    // @metadata(min=1 max=60 default=18)
    int taps;
};

void main() {
    vec4 trail = vec4(0.0);
    float weight = 1.0;
    float total = 0.0;
    int count = min(taps, uFrameCount);

    for (int i = 0; i < 60; i++) {
        if (i >= count) { break; }
        trail += ceHistory(vUV, i) * weight;
        total += weight;
        weight *= 0.82;
    }

    outColor = mix(texture(uPrev, vUV), trail / max(total, 0.0001), ghosting);
}
