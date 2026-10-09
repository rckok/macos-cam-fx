// The trails screened over a dimmed camera image.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=1.0 default=0.1)
    float background_level;
    // @metadata(min=0.0 max=1.0 default=1.0)
    float foreground_level;
    // @metadata(min=0.0 max=32.0 default=0.0 global)
    float particles_blur;
    // @metadata(default=0)
    uint show_bg;
};

void main() {
    vec3 bg = ceHistory(vUV, 0).rgb * background_level;
    vec3 fg = ceHistory(vUV, 0).rgb * foreground_level;
    vec3 trails = ceDiscBlur(uPrev, vUV, particles_blur, 8, 1.0).rgb;
    float person = texture(uPersonMatte, vUV).r;
    outColor = vec4((bg.rgb * show_bg + trails) * (1.0 - person) + fg.rgb * person, 1);
}
