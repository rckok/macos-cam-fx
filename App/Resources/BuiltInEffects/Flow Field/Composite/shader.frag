// The trails screened over a dimmed camera image.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=1.0 default=0.4 global)
    float cameraLevel;
};

void main() {
    vec3 camera = ceHistory(vUV, 0).rgb * cameraLevel;
    vec3 trails = texture(uPrev, vUV).rgb;
    outColor = vec4(1.0 - (1.0 - camera) * (1.0 - trails), 1.0);
}
