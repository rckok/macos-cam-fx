// Hand tracking visualization using vision data

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

void main() {
    vec4 cam = texture(uPrev, vUV);
    vec4 hands = texture(uHandMask, vUV);

    vec2 p = vUV * uResolution;
    vec3 color = vec3(0);
    const float boneWidth = 2.5;
    const float jointRadius = 5.0;
    const float jointMinConf = 0.3;
    const int boneCount = 20;
    const int bones[40] = int[](
        CE_WRIST, CE_THUMB_CMC,  CE_THUMB_CMC, CE_THUMB_MP,  CE_THUMB_MP, CE_THUMB_IP,  CE_THUMB_IP, CE_THUMB_TIP,
        CE_WRIST, CE_INDEX_MCP,  CE_INDEX_MCP, CE_INDEX_PIP,  CE_INDEX_PIP, CE_INDEX_DIP,  CE_INDEX_DIP, CE_INDEX_TIP,
        CE_WRIST, CE_MIDDLE_MCP, CE_MIDDLE_MCP, CE_MIDDLE_PIP, CE_MIDDLE_PIP, CE_MIDDLE_DIP, CE_MIDDLE_DIP, CE_MIDDLE_TIP,
        CE_WRIST, CE_RING_MCP,   CE_RING_MCP, CE_RING_PIP,    CE_RING_PIP, CE_RING_DIP,    CE_RING_DIP, CE_RING_TIP,
        CE_WRIST, CE_LITTLE_MCP, CE_LITTLE_MCP, CE_LITTLE_PIP, CE_LITTLE_PIP, CE_LITTLE_DIP, CE_LITTLE_DIP, CE_LITTLE_TIP
    );

    for (int h = 0; h < CE_MAX_HANDS; h++) {
        if (h >= uHandCount) { break; }
        float chirality = uHandInfo[h].x;
        vec3 handColor = chirality < 0.0 ? vec3(0.2, 0.85, 1.0)
                       : chirality > 0.0 ? vec3(1.0, 0.35, 0.75)
                       : vec3(1.0);
        for (int b = 0; b < boneCount; b++) {
            vec4 ja = ceHandJoint(h, bones[b * 2]);
            vec4 jb = ceHandJoint(h, bones[b * 2 + 1]);
            if (min(ja.z, jb.z) < jointMinConf) { continue; }
            float d = sdSegment(p, ja.xy * uResolution, jb.xy * uResolution);
            color = mix(handColor, color, smoothstep(boneWidth, boneWidth + 1.5, d));
        }
        for (int j = 0; j < CE_HAND_JOINTS; j++) {
            vec4 joint = ceHandJoint(h, j);
            if (joint.z < jointMinConf) { continue; }
            float d = distance(p, joint.xy * uResolution);
            color = mix(handColor, color, smoothstep(jointRadius, jointRadius + 1.5, d));
        }
    }

    outColor = cam + 0.2 * hands.r + vec4(color, 1);
}