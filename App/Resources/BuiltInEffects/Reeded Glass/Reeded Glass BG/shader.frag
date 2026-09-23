// Built-in uniforms are listed in the inspector. See README for details.

layout(std140, binding = 3) uniform Params {
    // @metadata(global min=10 max=200 default=55)
    int num_tiles;
    // @metadata(global)
    bool two_dimensional;
    // @metadata(min=-1.0 max=1.0 default=0.025)
    float displacement_radius;
};

// Generate displacement map: red for horizontal, green for vertical displacement
vec2 displacementMap(vec2 uv, vec2 numTiles, float radius, bool is2D) {
    vec2 size = vec2(1.0) / numTiles;
    vec2 tile = mod(uv, size) / size;
    vec2 displacement = vec2(tile.xy * vec2(1, float(is2D)));
    return 2.0 * (displacement - 0.5); // normalize to -1 : 1 range
}

void main() {
    vec2 disp = displacementMap(vUV,
                                vec2(num_tiles, num_tiles * uResolution.y / uResolution.x),
                                displacement_radius,
                                two_dimensional
                                );
    float person = texture(uPersonMatte, vUV).r;
    vec4 bg = texture(uPrev, vUV + disp * displacement_radius);
    // outColor = texture(uPrev, vUV + (1.0 - person) * disp * displacement_radius);
    outColor = mix(bg, ceHistory(vUV, 0), person);
}
