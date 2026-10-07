// Built-in uniforms are listed behind the editor's `{ }` button. See README for details.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=1.0 default=0.85)
    float magnify;        // 0..1  pull toward tile centre (1 = flat mosaic), ~0.85
    // @metadata(min=0.0 max=0.5 default=0.12)
    float edge_width;    // 0..0.5 fraction of the tile occupied by each bevel, ~0.12
    // @metadata(min=0.0 max=1.0 default=0.6)
    float edge_strength;  // bevel refraction, in tile units, ~0.6
    // @metadata(min=1.0 max=3.0 default=2.5)
    float edge_power;     // bevel falloff shape, 1 = linear, 2-3 = rounded, ~2.5
    // @metadata(min=0.0 max=1.0 default=0.1)
    float jitter;        // 0..1 per-tile random variation of the lens, ~0.1
    // @metadata(min=1 max=100 default=50 global)
    int num_tiles;
};

#define ENCODE_RAW 1

float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Displacement along one axis, in tile units.
// t is the local coordinate inside the tile, in [-0.5, 0.5).
float axisDisp(float t, float mag, out float edge)
{
    // Lens body: sample closer to the tile centre -> magnification.
    float lens = -t * mag;

    // Bevel: rises steeply toward the tile border and bends the ray outward.
    float a = abs(t) * 2.0;                                  // 0 centre, 1 border
    edge = smoothstep(1.0 - 2.0 * edge_width, 1.0, a);
    float bevel = sign(t) * pow(edge, edge_power) * edge_strength;

    return lens + bevel;
}

void main() {
    vec2 cellSize = vec2(1.0, uResolution.x / uResolution.y) / num_tiles;
    float maxDisp = max(cellSize.x, cellSize.y) * (0.5 * magnify + edge_strength) * 1.1;
    
    vec2 p    = vUV;
    vec2 cell = floor(p / cellSize);
    vec2 t    = fract(p / cellSize) - 0.5;

    // Slight per-tile variation so the blocks don't look perfectly identical.
    float r   = hash12(cell) * 2.0 - 1.0;
    float mag = clamp(magnify * (1.0 + r * jitter), 0.0, 1.0);

    float ex, ey;
    vec2 dTile = vec2(axisDisp(t.x, mag, ex),
                      axisDisp(t.y, mag, ey));

    vec2  d    = dTile * cellSize;
    float edge = max(ex, ey);
    
#if ENCODE_RAW
    vec4 m = vec4(d, edge, 1.0);
    vec2  dPx  = m.rg;
#else
    vec4 m = vec4(0.5 + d / (2.0 * maxDisp), edge, 1.0);
    vec2  dPx  = (m.rg - 0.5) * 2.0 * maxDisp;
#endif

    float person = texture(uPersonMatte, vUV).r;
    vec4 bg = texture(uPrev, vUV + dPx);//ceHistory(vUV + dPx, 0);
    outColor = mix(bg, ceHistory(vUV, 0), person);
}
