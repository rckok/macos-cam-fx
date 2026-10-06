void main() {
    // Round points.
    if (length(gl_PointCoord - 0.5) > 0.5) { discard; }
    outColor = vColor;
}
