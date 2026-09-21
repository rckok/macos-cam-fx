// Radial slitscan effect, centered around the tip of the nose

layout(std140, binding = 3) uniform Params {
    // @metadata(global)
    float historySize;
};

void main() {
    vec2 center = vec2(0.5);
    float dist = 1;
    // if (uFaceCount > 0) {
    //     center = uFaceRects[0].xy + 0.5 * uFaceRects[0].zw;
    // }
    
    for (int i = 0; i < CE_MAX_FACES; i++) {
        if (i >= uFaceCount) { break; }
        vec2 c = uFaceRects[i].xy + 0.5 * uFaceRects[i].zw;
        float d = length(abs(vUV - c));
        if (d < dist) {
            center = c;
            dist = d;
        }
    }
    
    float distFromCenter = dist;//length(abs(vUV - center));
    
    float frameCount = float(uFrameCount);
    float ago = distFromCenter * historySize * frameCount;
    
    float idx = mod(mod(float(uHeadIndex - ago), frameCount) + frameCount, frameCount); // wrap
    float z = (idx + 0.5) / frameCount;  // center of the slice
    vec4 color = texture(uFrames, vec3(vUV, z));
    
    outColor = color;// * (1.0 - ago / float(uFrameCount)); // vignette
}
