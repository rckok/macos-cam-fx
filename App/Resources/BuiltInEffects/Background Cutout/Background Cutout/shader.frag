// Background subtraction demo using the person-segmentation luma matte
// (uPersonMatte). The segmentation model only runs while a stage of the
// active effect samples uPersonMatte.
//
// Replaces everything outside the detected person with a solid color.
// `threshold` sets the matte cutoff, `softness` feathers the edge.

layout(std140, binding = 3) uniform Params {
    // @metadata(color=true default=vec3(0.1, 0.8, 0.2) global)
    vec3 backgroundColor;
    // @metadata(min=0.0 max=1.0 default=0.5 global)
    float threshold;
    // @metadata(min=0.0 max=1.0 default=0.25 global)
    float softness;
};

void main() {
    vec4 camera = texture(uPrev, vUV);
    float matte = texture(uPersonMatte, vUV).r;
    float edge = max(softness, 0.001) * 0.5;
    float person = smoothstep(threshold - edge, threshold + edge, matte);
    outColor = vec4(mix(backgroundColor, camera.rgb, person), camera.a);
}
