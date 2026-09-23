// Built-in uniforms are listed in the inspector. See README for details.

layout(std140, binding = 3) uniform Params {
    // @metadata(global min=1 max=50 default=16)
    int pixel_size;
};

void main() {
    float person = texture(uPersonMatte, vUV).r;
    vec2 pixel = vec2(pixel_size / uResolution.x, pixel_size / uResolution.y);
    vec2 tile = round(vUV / pixel) * pixel;
    vec4 bg = texture(uPrev, tile);
    outColor = mix(bg, ceHistory(vUV, 0), person);
}
