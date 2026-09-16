// Stage 1 of the "Light Trails" effect: lays the trails over the live camera
// frame. It reads the Trail Buffer stage by name rather than through uPrev,
// so it keeps working if stages are reordered, and the buffer stage keeps
// rendering even though nothing here samples uPrev. The index form,
// ceStageTexture(0, uv), works too.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0.0 max=2.0 default=1.0 global)
    float amount;
};

void main() {
    vec4 camera = ceHistory(vUV, 0);
    vec4 trails = ceStageTexture("Trail Buffer", vUV);
    outColor = vec4(camera.rgb + trails.rgb * amount, camera.a);
}
