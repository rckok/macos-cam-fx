// Body pose visualization using vision data

float sdSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h);
}

// The person's own left (cyan), right (pink), or center line (white).
vec3 sideColor(int joint) {
    bool left = joint == CE_BODY_LEFT_EYE || joint == CE_BODY_LEFT_EAR
             || joint == CE_BODY_LEFT_SHOULDER || joint == CE_BODY_LEFT_ELBOW
             || joint == CE_BODY_LEFT_WRIST || joint == CE_BODY_LEFT_HIP
             || joint == CE_BODY_LEFT_KNEE || joint == CE_BODY_LEFT_ANKLE;
    bool right = joint == CE_BODY_RIGHT_EYE || joint == CE_BODY_RIGHT_EAR
              || joint == CE_BODY_RIGHT_SHOULDER || joint == CE_BODY_RIGHT_ELBOW
              || joint == CE_BODY_RIGHT_WRIST || joint == CE_BODY_RIGHT_HIP
              || joint == CE_BODY_RIGHT_KNEE || joint == CE_BODY_RIGHT_ANKLE;
    return left ? vec3(0.2, 0.85, 1.0) : right ? vec3(1.0, 0.35, 0.75) : vec3(1.0);
}

void main() {
    vec4 cam = texture(uPrev, vUV);

    vec2 p = vUV * uResolution;
    vec3 color = vec3(0);
    float coverage = 0.0;
    const float boneWidth = 3.0;
    const float jointRadius = 6.0;
    const float jointMinConf = 0.3;
    const int boneCount = 18;
    // Bones are listed outward from the torso, so the second joint decides the color.
    const int bones[36] = int[](
        CE_BODY_NECK, CE_BODY_NOSE,
        CE_BODY_NOSE, CE_BODY_LEFT_EYE,           CE_BODY_NOSE, CE_BODY_RIGHT_EYE,
        CE_BODY_LEFT_EYE, CE_BODY_LEFT_EAR,       CE_BODY_RIGHT_EYE, CE_BODY_RIGHT_EAR,
        CE_BODY_NECK, CE_BODY_LEFT_SHOULDER,      CE_BODY_NECK, CE_BODY_RIGHT_SHOULDER,
        CE_BODY_LEFT_SHOULDER, CE_BODY_LEFT_ELBOW, CE_BODY_RIGHT_SHOULDER, CE_BODY_RIGHT_ELBOW,
        CE_BODY_LEFT_ELBOW, CE_BODY_LEFT_WRIST,   CE_BODY_RIGHT_ELBOW, CE_BODY_RIGHT_WRIST,
        CE_BODY_NECK, CE_BODY_ROOT,
        CE_BODY_ROOT, CE_BODY_LEFT_HIP,           CE_BODY_ROOT, CE_BODY_RIGHT_HIP,
        CE_BODY_LEFT_HIP, CE_BODY_LEFT_KNEE,      CE_BODY_RIGHT_HIP, CE_BODY_RIGHT_KNEE,
        CE_BODY_LEFT_KNEE, CE_BODY_LEFT_ANKLE,    CE_BODY_RIGHT_KNEE, CE_BODY_RIGHT_ANKLE
    );

    for (int b = 0; b < CE_MAX_BODIES; b++) {
        if (b >= uBodyCount) { break; }
        for (int i = 0; i < boneCount; i++) {
            vec4 ja = ceBodyJoint(b, bones[i * 2]);
            vec4 jb = ceBodyJoint(b, bones[i * 2 + 1]);
            if (min(ja.z, jb.z) < jointMinConf) { continue; }
            float d = sdSegment(p, ja.xy * uResolution, jb.xy * uResolution);
            float a = 1.0 - smoothstep(boneWidth, boneWidth + 1.5, d);
            color = mix(color, sideColor(bones[i * 2 + 1]), a);
            coverage = max(coverage, a);
        }
        for (int j = 0; j < CE_BODY_JOINTS; j++) {
            vec4 joint = ceBodyJoint(b, j);
            if (joint.z < jointMinConf) { continue; }
            float d = distance(p, joint.xy * uResolution);
            float a = 1.0 - smoothstep(jointRadius, jointRadius + 1.5, d);
            color = mix(color, vec3(1.0, 0.85, 0.2), a);
            coverage = max(coverage, a);
        }
    }

    outColor = vec4(mix(cam.rgb, color, coverage), 1.0);
}
