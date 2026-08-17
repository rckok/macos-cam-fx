// Time-smear effect demonstrating the 3D frame-history texture: blends the
// last `taps` frames with exponentially decaying weights, producing motion
// trails.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=1.0 default=0.85)
    float decay;
    // @metadata(min=1 max=120 default=24)
    int taps;
};

void main() {
    vec4 accumulated = vec4(0.0);
    float weight = 1.0;
    float totalWeight = 0.0;
    int count = min(taps, uFrameCount);

    for (int i = 0; i < 120; i++) {
        if (i >= count) { break; }
        accumulated += ceHistory(vUV, i) * weight;
        totalWeight += weight;
        weight *= decay;
    }

    outColor = accumulated / max(totalWeight, 0.0001);
}
