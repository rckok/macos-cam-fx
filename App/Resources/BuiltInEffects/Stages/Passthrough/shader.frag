// Passes the camera frame through unchanged. Useful as a starting point, and
// as the "no effect" entry in the effects list.

void main() {
    outColor = texture(uPrev, vUV);
}
