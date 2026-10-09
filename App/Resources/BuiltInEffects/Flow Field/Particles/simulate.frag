layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=1.0 default=0.2 global)
    float spread;
    // @metadata(min=0.001 max=1.0 default=0.05)
    float steering;
    // @metadata(min=0.001 max=1.0 default=0.05)
    float speed_change;
    // @metadata(min=0.001 max=0.15 default=0.003)
    float max_speed;
    // @metadata(min=0.001 max=1.0 default=0.1)
    float color_change;
    bool undulateDirection;
};

float person(vec2 uv) {
    return texture(uPersonMatte, uv).r;
}

vec2 colorToMotion(vec3 color, float jitter) {
    float r = step(ceItemIndex, 0.33 * uCount); // first 1/3rd of particles follow red
    float g = step(ceItemIndex, 0.67 * uCount) - r; // second 1/3rd of particles follow green
    float b = step(0.67 * uCount, ceItemIndex); // third 1/3rd of particles follow blue
    vec3 mult = vec3(r, g, b);
    float angle = max(mult * color);
    angle += jitter * spread;
    if (undulateDirection) angle += sin(0.01 * uTime);
    float speed = min(luminance(color), max_speed);
    speed = sign(speed) * max(abs(speed), 0.0001); // prevent stationary particles
    return vec2(angle, speed);
}

void main() {
    vec4 posvel = ceState(0, ceItemIndex); // particle position and velocity in first state
    vec2 position = posvel.xy;
    float angle = posvel.z;
    float speed = posvel.w;
    vec4 color = ceState(1, ceItemIndex); // particle color stored in second state
    
    if (uSimFrame == 0) {
        vec4 random = ceHash4(ceItemIndex * 7919 + uSimFrame * 104729 + uSubstep);
        vec2 pos = random.xy;
        vec4 cam = ceHistory(pos, 0);
        vec2 motion = colorToMotion(cam.rgb, random.z);//ceHash(ceItemIndex * 7919));
        outState0 = vec4(pos, motion);
        outState1 = cam;
        return;
    }
    
    // sample camera at particle position
    vec4 camera = ceHistory(position, 0);
    
    vec2 motion = ceCameraMotion(position, 16.0);
    motion *= step(0.01, abs(motion));
    
    // calculate movement from angle and speed
    vec2 step = vec2(cos(angle * TWO_PI) * speed, sin(angle * TWO_PI) * speed) + motion * uSimDelta;
    vec2 next_pos = mod(position + step, vec2(1));
    if (next_pos.x < 0.0) next_pos.x += 1.0;
    if (next_pos.y < 0.0) next_pos.y += 1.0;
    
    vec2 new_motion = colorToMotion(camera.rgb, ceHash(ceItemIndex * 7919));//ceNoise(position * uResolution));
    float next_angle = mix(angle, new_motion.x, steering);
    float next_speed = mix(speed, new_motion.y, speed_change);
    
    // set to next position and update angle and speed based on camera input
    outState0 = vec4(next_pos, next_angle, next_speed);
    // change particle color to follow camera input, but slowly
    outState1 = mix(color, camera, color_change);
}
