// A single-pass compressible fluid ("Simple and Fast Fluids", Guay, Colin &
// Egli 2011) on a grid of Count cells shaped like the frame. Density stands
// in for pressure, so there is no pressure solve: each cell reads only its
// four neighbors and one back-traced point per step.
//
// State slot 0: velocity in cells per step (xy), density (z), curl (w).
// State slot 1: dye color (rgb), seeded from the camera frame.

layout(std140, binding = 3) uniform Params {
    // How strongly the fluid takes on the camera's motion: 1 moves it with
    // the scene, lower values only nudge it.
    // @metadata(min=0.0 max=1.0 default=0.6 global)
    float motion_force;
    // Motion search window in pixels; also the fastest motion followed per frame.
    // @metadata(min=8.0 max=64.0 default=24.0)
    float motion_radius;
    // Motion below this many pixels per frame is camera noise and ignored.
    // @metadata(min=0.0 max=4.0 default=0.75)
    float motion_threshold;
    // @metadata(min=0.0 max=0.15 default=0.05)
    float pressure;
    // @metadata(min=0.0 max=0.1 default=0.05)
    float viscosity;
    // @metadata(min=0.0 max=0.3 default=0.1 global)
    float vorticity;
    // Velocity kept per step; lower values make the fluid settle sooner.
    // @metadata(min=0.9 max=1.0 default=0.998)
    float persistence;
    // How fast the dye returns to the live camera image; 0 keeps the seed.
    // @metadata(min=0.0 max=0.05 default=0.0 global)
    float camera_refresh;
};

ivec2 fluidGrid() {
    int width = max(int(sqrt(float(uCount) * uResolution.x / uResolution.y) + 0.5), 1);
    return ivec2(width, max(uCount / width, 1));
}

vec4 cell(int slot, ivec2 c, ivec2 grid) {
    c = clamp(c, ivec2(0), grid - 1);
    return ceState(slot, c.y * grid.x + c.x);
}

// Bilinear read at `p` in cells, cell centers on whole numbers.
vec4 sampleGrid(int slot, vec2 p, ivec2 grid) {
    ivec2 i = ivec2(floor(p));
    vec2 f = p - vec2(i);
    return mix(
        mix(cell(slot, i, grid), cell(slot, i + ivec2(1, 0), grid), f.x),
        mix(cell(slot, i + ivec2(0, 1), grid), cell(slot, i + ivec2(1, 1), grid), f.x),
        f.y
    );
}

void main() {
    ivec2 grid = fluidGrid();
    if (ceItemIndex >= grid.x * grid.y) {
        outState0 = vec4(0.0);
        outState1 = vec4(0.0);
        return;
    }
    ivec2 c = ivec2(ceItemIndex % grid.x, ceItemIndex / grid.x);
    vec2 uv = (vec2(c) + 0.5) / vec2(grid);

    if (uSimFrame == 0) {
        outState0 = vec4(0.0, 0.0, 1.0, 0.0);
        outState1 = vec4(ceHistory(uv, 0).rgb, 1.0);
        return;
    }

    vec4 here = cell(0, c, grid);
    vec4 right = cell(0, c + ivec2(1, 0), grid);
    vec4 left = cell(0, c - ivec2(1, 0), grid);
    vec4 down = cell(0, c + ivec2(0, 1), grid);
    vec4 up = cell(0, c - ivec2(0, 1), grid);

    vec3 dx = (right.xyz - left.xyz) * 0.5;
    vec3 dy = (down.xyz - up.xyz) * 0.5;
    float divergence = dx.x + dy.y;
    vec2 densityGradient = vec2(dx.z, dy.z);
    float curl = dx.y - dy.x;

    // Mass conservation; the clamp keeps strong pushes from emptying or
    // overfilling cells.
    float density = clamp(here.z - dot(vec3(densityGradient, divergence), here.xyz), 0.5, 3.0);

    vec2 from = vec2(c) - here.xy;
    vec2 velocity = sampleGrid(0, from, grid).xy;
    velocity += viscosity * (right.xy + left.xy + down.xy + up.xy - 4.0 * here.xy);
    velocity -= pressure * densityGradient;

    // Vorticity confinement from the neighbors' curl of the previous step,
    // restoring the swirls that advection smooths away.
    vec2 eta = vec2(abs(right.w) - abs(left.w), abs(down.w) - abs(up.w));
    eta /= length(eta) + 1e-5;
    velocity += vorticity * here.w * vec2(eta.y, -eta.x);

    // Camera motion changes once per frame. Moving parts of the scene drag
    // the fluid toward their own velocity, converted to cells per step;
    // still parts leave it alone.
    if (uSubstep == 0) {
        vec2 motion = ceCameraMotion(uv, motion_radius);
        float pixelsPerFrame = length(motion * uTimeDelta * uResolution);
        float moving = smoothstep(motion_threshold, motion_threshold * 2.0 + 0.5, pixelsPerFrame);
        velocity = mix(velocity, motion * vec2(grid) * uSimDelta, motion_force * moving);
    }

    velocity *= persistence;
    if (c.x == 0 || c.x == grid.x - 1) { velocity.x = 0.0; }
    if (c.y == 0 || c.y == grid.y - 1) { velocity.y = 0.0; }
    float speed = length(velocity);
    if (speed > 3.0) { velocity *= 3.0 / speed; }

    vec3 dye = sampleGrid(1, from, grid).rgb;
    dye = mix(dye, ceHistory(uv, 0).rgb, camera_refresh);

    outState0 = vec4(velocity, density, curl);
    outState1 = vec4(dye, 1.0);
}
