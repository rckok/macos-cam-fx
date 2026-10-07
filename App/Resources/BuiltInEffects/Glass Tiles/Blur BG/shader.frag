// Built-in uniforms are listed in the inspector. See README for details.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=64.0 default=0.0 global)
    float blur_background;
};

void main() {
    outColor = ceDiscBlur(uPrev, vUV, blur_background, 24, 1.0);
}
