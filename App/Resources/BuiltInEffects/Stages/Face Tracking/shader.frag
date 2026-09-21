// Face tracking visualization using vision data

float PI = 3.1415926535;

float sdSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h);
}

// Axis-aligned box outline in pixel space. `rect` is xy = top-left, zw = size (vUV).
float sdBoxOutline(vec2 pPx, vec4 rect) {
    vec2 bmin = rect.xy * uResolution;
    vec2 bmax = (rect.xy + rect.zw) * uResolution;
    vec2 c = 0.5 * (bmin + bmax);
    vec2 h = 0.5 * (bmax - bmin);
    vec2 d = abs(pPx - c) - h;
    return abs(length(max(d, 0.0)) + min(max(d.x, d.y), 0.0));
}

float segmentDistance(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
    return distance(p, a + t * ab);
}

float showFaceLandmark(vec4 landmark, vec2 uv, vec2 resolution, vec2 dir, float thickness) {
    // xy = uv position, z = found (1) or not (0), w = half width
    //return eye.z >= 0.5 ? step(0.005, length(uv - eye.xy)) : 0.0;
    vec2 p = uv * resolution;
    if (landmark.z < 0.5) { return 1.0; }
    vec2 center = landmark.xy * resolution;
    float halfWidth = landmark.w * resolution.x;
    
    float d = segmentDistance(p, center - dir * vec2(halfWidth),
                                 center + dir * vec2(halfWidth));
    return smoothstep(thickness - 1.0, thickness + 1.0, d);
}

void main() {
    vec4 cam = texture(uPrev, vUV);
    vec4 face = texture(uFaceMask, vUV);

    vec2 p = vUV * uResolution;
    const float boxWidth = 2.0;
    vec3 bboxColor = vec3(0);
    float pupils = 1.0;
    float mouthCenterLine = 0.0;

    for (int i = 0; i < CE_MAX_FACES; i++) {
        if (i >= uFaceCount) { break; }
        float d = sdBoxOutline(p, uFaceRects[i]);
        bboxColor = mix(vec3(0.15, 0.95, 0.35), bboxColor, smoothstep(boxWidth, boxWidth + 1.5, d));
        
        vec4 leftEye = uFaceLeftEye[i];
        vec4 rightEye = uFaceRightEye[i];
        vec4 mouth = uFaceMouth[i];
        
        vec2 dir = vec2(1.0, 0.0);
        float angle = 0.0;
        if (leftEye.z > 0.5 && rightEye.z > 0.5) {
            dir = normalize((rightEye.xy - leftEye.xy) * uResolution);
        }
        
        pupils = showFaceLandmark(leftEye, vUV, uResolution, dir, 1.0) * showFaceLandmark(rightEye, vUV, uResolution, dir, 1.0);
        pupils *= step(0.006, length(vUV - leftEye.xy));
        pupils *= step(0.006, length(vUV - rightEye.xy));
        mouthCenterLine = showFaceLandmark(mouth, vUV, uResolution, dir, 3.0);
        mouthCenterLine *= step(0.01, length(vUV - mouth.xy));
    }

    outColor = (cam + face + vec4(bboxColor, 1)) * pupils * mouthCenterLine;
}
