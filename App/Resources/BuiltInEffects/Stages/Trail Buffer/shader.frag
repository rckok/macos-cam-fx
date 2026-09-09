// Stage 0 of the "Light Trails" effect: a feedback buffer. ceSelfTexture()
// returns this stage's own output from the previous frame, so bright pixels
// persist and fade instead of vanishing with the next camera frame. Every
// stage gets this for free — its output lives in its own slice of
// uStageTextures, which is only overwritten after the stage has run.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=1.0 default=0.92 global)
    float decay;
    // @metadata(min=0.0 max=1.0 default=0.55)
    float threshold;
};

void main() {
    vec4 camera = texture(uPrev, vUV);
    vec4 previous = ceSelfTexture(vUV) * decay;

    float brightness = dot(camera.rgb, vec3(0.299, 0.587, 0.114));
    float highlight = smoothstep(threshold, 1.0, brightness);

    outColor = max(previous, vec4(camera.rgb * highlight, 1.0));
}
