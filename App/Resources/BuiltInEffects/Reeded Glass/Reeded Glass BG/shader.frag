// Built-in uniforms are listed in the inspector. See README for details.

layout(std140, binding = 3) uniform Params {
    // @metadata(global min=10 max=200 default=55)
    int num_tiles;
    // @metadata(min=-1.0 max=1.0 default=0.025)
    float displacement_radius;
};


void main() {
    float displacement = 2.0 * (fract(vUV.x / (1.0 / float(num_tiles))) - 0.5); // -1 to 1
    vec4 bg = texture(uPrev, vUV + vec2(displacement * displacement_radius, 0));
    vec4 camera = ceHistory(vUV, 0);
    float person = texture(uPersonMatte, vUV).r;
    outColor = mix(bg, camera, person);
}
