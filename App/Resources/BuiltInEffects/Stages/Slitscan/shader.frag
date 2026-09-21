// Gradient-driven slitscan effect

layout(std140, binding = 3) uniform Params {
    // @metadata(global)
    float historySize;
};

#define PI 3.14159265359

void main() {
    float frameCount = float(uFrameCount);
    float ago = 2.0 * abs(vUV.y - 0.5) * historySize * frameCount;

    float idx = mod(mod(float(uHeadIndex - ago), frameCount) + frameCount, frameCount); // wrap
    float z = (idx + 0.5) / frameCount;  // center of the slice
    outColor = texture(uFrames, vec3(vUV, z));
}
