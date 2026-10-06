// Particles drifting along a curl-noise flow field, streaming around the
// person in front of the camera. One state slot per particle:
// xy = position (vUV space), z = age, w = lifetime, all in seconds.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=0.5 default=0.12 global)
    float speed;
    // @metadata(min=0.5 max=10.0 default=2.5)
    float noiseScale;
    // @metadata(min=0.0 max=4.0 default=1.5 global)
    float avoidPerson;
    // @metadata(min=0.5 max=10.0 default=5.0)
    float lifetime;
};

float person(vec2 uv) {
    return texture(uPersonMatte, uv).r;
}

void main() {
    vec4 state = ceState(0, ceItemIndex);
    bool outside = any(lessThan(state.xy, vec2(0.0))) || any(greaterThan(state.xy, vec2(1.0)));

    if (uSimFrame == 0 || state.z >= state.w || outside) {
        vec4 random = ceHash4(ceItemIndex * 7919 + uSimFrame * 104729 + uSubstep);
        float age = uSimFrame == 0 ? random.z * lifetime : 0.0;
        outState0 = vec4(random.xy, age, lifetime * (0.5 + random.w));
        return;
    }

    vec2 aspect = vec2(uResolution.y / uResolution.x, 1.0);
    vec2 flow = ceCurlNoise(state.xy / aspect * noiseScale, uTime * 0.1) * aspect;

    // Down the person matte's slope: away from the silhouette's edge.
    const float e = 0.01;
    vec2 slope = vec2(
        person(state.xy + vec2(e, 0.0)) - person(state.xy - vec2(e, 0.0)),
        person(state.xy + vec2(0.0, e)) - person(state.xy - vec2(0.0, e))
    );
    flow -= slope * avoidPerson * 3.0;

    outState0 = vec4(state.xy + flow * speed * uSimDelta, state.z + uSimDelta, state.w);
}
