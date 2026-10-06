// One point per particle, tinted by the camera under it. Particles fade in
// and out over their lifetime, and mostly out over the person.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=1.0 max=8.0 default=2.0)
    float pointSize;
    // @metadata(min=0.0 max=1.0 default=0.6 global)
    float brightness;
};

void main() {
    vec4 state = ceState(0, ceItemIndex);
    float life = clamp(state.z / max(state.w, 0.0001), 0.0, 1.0);
    float behind = texture(uPersonMatte, state.xy).r;

    ceEmit(state.xy);
    gl_PointSize = pointSize;
    vec3 color = mix(vec3(1.0), ceHistory(state.xy, 0).rgb, 0.6);
    vColor = vec4(color, sin(life * 3.14159265) * brightness * (1.0 - 0.8 * behind));
}
