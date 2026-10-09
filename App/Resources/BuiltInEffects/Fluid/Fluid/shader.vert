// One quad per simulated cell; together they tile the frame.

ivec2 fluidGrid() {
    int width = max(int(sqrt(float(uCount) * uResolution.x / uResolution.y) + 0.5), 1);
    return ivec2(width, max(uCount / width, 1));
}

void main() {
    ivec2 grid = fluidGrid();
    if (ceItemIndex >= grid.x * grid.y) {
        ceEmit(vec2(-2.0));
        return;
    }
    vec2 c = vec2(ceItemIndex % grid.x, ceItemIndex / grid.x);
    ceEmit((c + ceQuadCorner(ceVertexIndex) * 0.5 + 0.5) / vec2(grid));
}
