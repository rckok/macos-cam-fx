layout(std140, binding = 3) uniform Params {
    // @metadata(min=vec3(0) max=vec3(1, 2, 2) default=vec3(0, 1, 1))
    vec3 hsb;
};

vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

vec3 postProcess(vec3 rgb, vec3 hsb) {
    vec3 hsv = rgb2hsv(rgb);
    return hsv2rgb(vec3(mod(hsv.x + hsb.x, 1.0), hsv.y * hsb.y, hsv.z * hsb.z));
}

float luminance(vec3 col) {
    return 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b;
}

void main() {
    vec4 color = texture(uPrev, vUV);
    color = vec4(postProcess(color.rgb, hsb), 1.0);
    
    outColor = color;
}
