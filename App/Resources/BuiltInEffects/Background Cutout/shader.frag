// Background subtraction demo using the person-segmentation luma matte
// (uPersonMatte). The segmentation model only runs while an effect that
// samples uPersonMatte is enabled.
//
// Replaces everything outside the detected person with a solid color.
// `threshold` sets the matte cutoff, `softness` feathers the edge.

layout(std140, binding = 3) uniform Params {
    vec3 backgroundColor;
    float threshold;
    float softness;
};

void main() {
    vec4 camera = texture(uPrev, vUV);
    float matte = texture(uPersonMatte, vUV).r;
    float edge = max(softness, 0.001) * 0.5;
    float person = smoothstep(threshold - edge, threshold + edge, matte);
    outColor = vec4(mix(backgroundColor, camera.rgb, person), camera.a);
}
