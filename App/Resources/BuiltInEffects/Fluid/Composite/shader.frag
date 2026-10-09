void main() {
    vec4 camera = ceHistory(vUV, 0);
    float person = texture(uPersonMatte, vUV).r;
    outColor = mix(texture(uPrev, vUV), camera, person);
}
