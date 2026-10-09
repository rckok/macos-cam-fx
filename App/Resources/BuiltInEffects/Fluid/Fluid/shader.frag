// The dye, interpolated between cell centers so the grid never shows.

ivec2 fluidGrid() {
    int width = max(int(sqrt(float(uCount) * uResolution.x / uResolution.y) + 0.5), 1);
    return ivec2(width, max(uCount / width, 1));
}

vec4 cell(ivec2 c, ivec2 grid) {
    c = clamp(c, ivec2(0), grid - 1);
    return ceState(1, c.y * grid.x + c.x);
}

void main() {
    ivec2 grid = fluidGrid();
    vec2 p = vUV * vec2(grid) - 0.5;
    ivec2 i = ivec2(floor(p));
    vec2 f = p - vec2(i);
    vec3 dye = mix(
        mix(cell(i, grid).rgb, cell(i + ivec2(1, 0), grid).rgb, f.x),
        mix(cell(i + ivec2(0, 1), grid).rgb, cell(i + ivec2(1, 1), grid).rgb, f.x),
        f.y
    );
    outColor = vec4(dye, 1.0);
}
