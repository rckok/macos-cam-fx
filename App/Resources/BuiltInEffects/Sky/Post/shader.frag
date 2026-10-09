layout(std140, binding = 3) uniform Params {
    // @metadata(min=vec3(0) max=vec3(1, 2, 2) default=vec3(0, 1, 1))
    vec3 hsb;
};

vec3 postProcess(vec3 rgb, vec3 hsb) {
    vec3 hsv = rgb2hsv(rgb);
    return hsv2rgb(vec3(mod(hsv.x + hsb.x, 1.0), hsv.y * hsb.y, hsv.z * hsb.z));
}

void main() {
    vec4 color = texture(uPrev, vUV);
    color = vec4(postProcess(color.rgb, hsb), 1.0);
    
    outColor = color;
}
