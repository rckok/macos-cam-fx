void main() {
    vec4 bg = texture(uPrev, vUV);
    vec4 cam = ceHistory(vUV, 0);
    vec4 person = texture(uPersonMatte, vUV);
    outColor = vec4(bg.rgb * (1.0 - person.r) + vec3(cam.rgb * person.r), 1);
}
