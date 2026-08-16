// Radial chromatic aberration: shifts red and blue channels outward from the
// center by an amount that grows with distance.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=2.0 default=1.0)
    float amount;
};

void main() {
    vec2 direction = vUV - vec2(0.5);
    vec2 shift = direction * amount * 0.05;

    float r = texture(uPrev, vUV - shift).r;
    float g = texture(uPrev, vUV).g;
    float b = texture(uPrev, vUV + shift).b;
    float a = texture(uPrev, vUV).a;

    outColor = vec4(r, g, b, a);
}
