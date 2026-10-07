// One point per particle, tinted by the camera under it. Particles fade in
// and out over their lifetime, and mostly out over the person.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=1.0 max=8.0 default=2.0)
    float pointSize;
};

void main() {
    vec2 position = ceState(0, ceItemIndex).xy;
    vec4 color = ceState(1, ceItemIndex);
       
    ceEmit(position);
    gl_PointSize = pointSize;
    vColor = color;
}
