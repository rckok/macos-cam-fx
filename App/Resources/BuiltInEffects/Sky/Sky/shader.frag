// Built-in uniforms are listed in the inspector. See README for details.

layout(std140, binding = 3) uniform Params {
    // @metadata(min=0 max=0.867021 default=0.12 global)
    float cloudy;
    // @metadata(min=-2.0 max=2.0 default=0.56 global)
    float cloudSpeed;
    // @metadata(min=0 max=0.4 default=0)
    float haze;
    // @metadata(min=0 max=100 default=70 global)
    float raininess;
    // @metadata(min=vec2(0, -0.04) max=vec2(1) default=vec2(0.7, 0.24) global)
    vec2 sunPos;
    bool autoSunY;
    // @metadata(min=0.0 max=1.0)
    float autoSunYSpeed;
    // @metadata(default=1 global)
    bool sunFollowsFinger;
    // @metadata(min=1.0 max=5.0 default=1.0)
    float sunIntensity;
    // @metadata(min=0.0 max=18 default=6.85)
    float lightPower;
    // @metadata(min=0.0 max=0.64 default=0.21)
    float lightConcentration;
    
    // @metadata(min=0.4 max=2.0 default=0.587)
    float fov;
    // @metadata(color=false default=vec3(0.051, 0.032, 0))
    vec3 cameraDirection;
    
    // @metadata(min=vec3(0) max=vec3(1, 2, 2) default=vec3(0, 1, 1))
    vec3 hsb;
};

float PI = 3.1415926535;

float sunConcentration = 0.999; //light concentration for sun

float minSunY = 0.173913;
float maxSunY = 0.282609;

//rendering quality
int steps = 16; //16 is fast, 128 or 256 is extreme high
int stepss = 16; //16 is fast, 16 or 32 is high

float cloudnear = 1.0; //9e3 12e3  //do not render too close clouds on the zenith
//float cloudfar = 1e3; //15e3 17e3
float cloudfar = 70e3; //160e3  //do not render too close clouds on the horizon 160km should be max for cumulus

float mincloudheight = 5e3; //5e3
float maxcloudheight = 8e3; //8e3
float cloudnoise = 2e-4; //2e-4

//Rayleigh scattering (sky color, atmospheric up to 8km)
vec3 bR = vec3(5.8e-6, 13.5e-6, 33.1e-6); //normal earth
//vec3 bR = vec3(5.8e-6, 33.1e-6, 13.5e-6); //purple
//vec3 bR = vec3( 63.5e-6, 13.1e-6, 50.8e-6 ); //green
//vec3 bR = vec3( 13.5e-6, 23.1e-6, 115.8e-6 ); //yellow
//vec3 bR = vec3( 5.5e-6, 15.1e-6, 355.8e-6 ); //yeellow
//vec3 bR = vec3(3.5e-6, 333.1e-6, 235.8e-6 ); //red-purple

//Mie scattering (water particles up to 1km)
vec3 bM = vec3(21e-6); //normal mie
//vec3 bM = vec3(50e-6); //high mie

//-----
//positions

float Hr = 8000.0; //Reyleight scattering top
float Hm = 1000.0; //Mie scattering top

float R0 = 6360e3; //planet radius
float Ra = 6380e3; //atmosphere radius
vec3 C = vec3(0., -R0, 0.); //planet center
vec3 Ds = normalize(vec3(0., .09, -1.)); //sun direction?

//--------------------------------------------------------------------------

// Camera

// Vertical FOV in radians. vUV is top-left origin (app convention).
vec3 cameraRay(vec2 screenUV, float fov, vec3 cameraDir) {
    float aspect = uResolution.x / uResolution.y;
    vec2 ndc = vec2(screenUV.x * 2.0 - 1.0, screenUV.y * 2.0); // +Y is screen-up
    float t = tan(fov * 0.5);
    vec3 view = normalize(vec3(ndc.x * aspect * t, ndc.y * t, 1.0));
    vec3 forward = dot(cameraDir, cameraDir) < 1e-12 ? vec3(0.0, 0.0, 1.0) : normalize(cameraDir);
    vec3 helper = abs(forward.y) > 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    vec3 right = normalize(cross(helper, forward));
    vec3 up = cross(forward, right);
    return normalize(right * view.x + up * view.y + forward * view.z);
}

// Inverse of generate()'s rotate_x then rotate_y mapping:
// uv.x in [0,1) = yaw, uv.y = 0 horizon / <0 sky / >0 ground
vec2 directionToSkyUV(vec3 dir) {
    return vec2(
        fract(-atan(dir.x, dir.z) / (2.0 * PI)),
        -asin(clamp(dir.y, -1.0, 1.0)) * (2.0 / PI)
    );
}

vec2 cameraToSphereUV(vec2 screenUV, float fov, vec3 cameraDir) {
    vec3 dir = cameraRay(screenUV, fov, cameraDir);
    return directionToSkyUV(dir);
}

// Cloud noise

float Hash(vec3 p)
{
    p  = fract(p * vec3(.16532,.17369,.15787));
    p += dot(p.xyz, p.yzx + 19.19);
    return fract(p.x * p.y * p.z);
}

float Noise(in vec3 p)
{
    vec3 i = floor(p);
    vec3 f = fract(p);
    f *= f * (3.0-2.0*f);

    return mix(
        mix(mix(Hash(i + vec3(0.,0.,0.)), Hash(i + vec3(1.,0.,0.)),f.x),
            mix(Hash(i + vec3(0.,1.,0.)), Hash(i + vec3(1.,1.,0.)),f.x),
            f.y),
        mix(mix(Hash(i + vec3(0.,0.,1.)), Hash(i + vec3(1.,0.,1.)),f.x),
            mix(Hash(i + vec3(0.,1.,1.)), Hash(i + vec3(1.,1.,1.)),f.x),
            f.y),
        f.z);
}

float fnoise(vec3 p, in float t)
{
    p *= .25;
    float f;

    f = 0.5000 * Noise(p); p = p * 3.02; p.y -= t * .1;
    f += 0.2500 * Noise(p); p = p * 3.03; p.y += t * .06;
    f += 0.1250 * Noise(p); p = p * 3.01;
    f += 0.0625   * Noise(p); p =  p * 3.03;
    f += 0.03125  * Noise(p); p =  p * 3.02;
    f += 0.015625 * Noise(p);
    return f;
}

//--------------------------------------------------------------------------
//clouds, scattering

float cloud(vec3 p, in float t) {
    float cld = fnoise(p * cloudnoise, 0.25 * t) + cloudy * 0.1;
    cld = smoothstep(.4 + .04, .6 + .04, cld);
    cld *= cld * (5.0 * raininess);
    return cld + haze;
}


void densities(in vec3 pos, out float rayleigh, out float mie, in float t) {
    float xaxiscloud = t * 5e2 * cloudSpeed; //t*5e2 +t left -t right *speed
    float yaxiscloud = 0.0;
    float zaxiscloud = t * 6e2 * cloudSpeed; //t*6e2 +t away from horizon -t towards horizon *speed
    
    float h = length(pos - C) - R0;
    rayleigh = exp(-h / Hr);
    vec3 d = pos;
    d.y = 0.0;
    float dist = length(d);

    float cld = 0.;
    if (mincloudheight < h && h < maxcloudheight) {
        //cld = cloud(pos+vec3(t*1e3,0., t*1e3),t)*cloudy;
        cld = cloud(pos + vec3(xaxiscloud, yaxiscloud, zaxiscloud), t) * cloudy; //direction and speed the cloud movers
        cld *= sin(3.1415 * (h - mincloudheight) / mincloudheight) * cloudy;
    }
    #ifdef cloud2
        float cld2 = 0.;
        if (12e3 < h && h < 15.5e3) {
            cld2 = fnoise(pos * 3e-4, t) * cloud(pos * 32.0 + vec3(27612.3, 0., -t * 15e3), t);
            cld2 *= sin(3.1413 * (h - 12e3) / 12e3) * cloudyhigh;
            cld2 = clamp(cld2, 0.0, 1.0);
        }
    #endif

    if (dist > cloudfar) {
        float factor = clamp(1.0 - ((dist - cloudfar) / (cloudfar - cloudnear)), 0.0, 1.0);
        cld *= factor;
    }

    mie = exp(-h / Hm) + cld + haze;
    #ifdef cloud2
        mie += cld2;
    #endif
}

float escape(in vec3 p, in vec3 d, in float R) {
    vec3 v = p - C;
    float b = dot(v, d);
    float c = dot(v, v) - R*R;
    float det2 = b * b - c;
    if (det2 < 0.) return -1.;
    float det = sqrt(det2);
    float t1 = -b - det, t2 = -b + det;
    return (t1 >= 0.) ? t1 : t2;
}

// this can be explained: http://www.scratchapixel.com/lessons/3d-advanced-lessons/simulating-the-colors-of-the-sky/atmospheric-scattering/
void scatter(vec3 o, vec3 d, out vec3 col, out vec3 scat, in float t, in vec3 sunColor) {
    float L = escape(o, d, Ra);
    float mu = dot(d, Ds);
    float opmu2 = 1. + mu * mu;
    float lc = lightConcentration;
    float lc2 = lc * lc;
    float s = sunConcentration;
    float s2 = s * s;
    float phaseR = .0596831 * opmu2;
    float phaseM = .1193662 * (1. - lc2) * opmu2 / ((2. + lc2) * pow(1. + lc2 - 2. * lc * mu, 1.5));
    float phaseS = .1193662 * (1. - s2) * opmu2 / ((2. + s2) * pow(1. + s2 - 2. * s * mu, 1.5));

    float depthR = 0., depthM = 0.;
    vec3 R = vec3(0.), M = vec3(0.);

    float dl = L / float(steps);
    for (int i = 0; i < steps; ++i) {
        float l = float(i) * dl;
        vec3 p = o + d * l;

        float dR, dM;
        densities(p, dR, dM, t);
        dR *= dl;
        dM *= dl;
        depthR += dR;
        depthM += dM;

        float Ls = escape(p, Ds, Ra);
        if (Ls > 0.) {
            float dls = Ls / float(stepss);
            float depthRs = 0., depthMs = 0.;
            for (int j = 0; j < stepss; ++j) {
                float ls = float(j) * dls;
                vec3 ps = p + Ds * ls;
                float dRs, dMs;
                densities(ps, dRs, dMs, t);
                depthRs += dRs * dls;
                depthMs += dMs * dls;
            }

            vec3 A = exp(-(bR * (depthRs + depthR) + bM * (depthMs + depthM))) * sunColor;
            R += A * dR;
            M += A * dM;
        }
    }
    
    col = lightPower * (M * bM * phaseM) * sunColor; // Mie scattering
    col += sunIntensity * (M * bM * phaseS) * sunColor; //Sun
    col += lightPower * (R * bR * phaseR) * sunColor; //Rayleigh scattering
    scat = 0.1 * (bM * clamp(depthM * 5e-7, 0., 1.));
//    scat = 0.0 + clamp(depthM * 5e-7, 0., 1.);
}

//--------------------------------------------------------------------------
// ray casting

vec3 rotate_y(vec3 v, float angle)
{
    float ca = cos(angle); float sa = sin(angle);
    return v * mat3(
        +ca, +.0, -sa,
        +.0,+1.0, +.0,
        +sa, +.0, +ca);
}

vec3 rotate_x(vec3 v, float angle)
{
    float ca = cos(angle); float sa = sin(angle);
    return v * mat3(
        +1.0, +.0, +.0,
        +.0, +ca, -sa,
        +.0, +sa, +ca);
}

vec4 generate(in vec2 uv, in vec2 sunPos, in float t, in vec3 sunColor) {
    
    float att = 1.0;
    
    float height = uResolution.y;
    vec3 O = vec3(0., height, 0.);

    vec3 D = normalize(
        rotate_y(
            rotate_x(
                vec3(0.0, 0.0, 1.0),
                -uv.y * PI / 2.0
            ),
            -uv.x * 2.0 * PI
        )
    );
    
    Ds = normalize(
        rotate_y(
            rotate_x(
                vec3(0.0, 0.0, 1.0),
                -sunPos.y * PI / 2.0
            ),
            -sunPos.x * 2.0 * PI
        )
    );
    
    vec3 color = vec3(0.);
    vec3 scat = vec3(0.);
    scatter(O, D, color, scat, t, sunColor);
    
    color += scat;
    
    float env = 1.0;
    return(vec4(env * pow(color, vec3(.7)), 1.0));
}

float map(float value, float min1, float max1, float min2, float max2) {
  return min2 + (value - min1) * (max2 - min2) / (max1 - min1);
}

vec2 map(vec2 value, vec2 min1, vec2 max1, vec2 min2, vec2 max2) {
  return min2 + (value - min1) * (max2 - min2) / (max1 - min1);
}

vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

vec3 postProcess(vec3 rgb, vec3 hsb) {
    vec3 hsv = rgb2hsv(rgb);
    return hsv2rgb(vec3(mod(hsv.x + hsb.x, 1.0), hsv.y * hsb.y, hsv.z * hsb.z));
}

float luminance(vec3 col) {
    return 0.21 * col.r + 0.72 * col.g + 0.07 * col.b;
}

void main() {
    //vec2 uv = vec2(vUV.x, 1.0 - vUV.y) / scale;
    vec2 uv = cameraToSphereUV(vUV, fov, cameraDirection * vec3(1, -1, 1));
    
    vec2 sunPosition = vec2(sunPos.x, autoSunY && autoSunYSpeed > 0.0 ? 0.5 + 0.54 * sin(uTime * autoSunYSpeed) : sunPos.y);
    
    if (sunFollowsFinger && uHandCount > 0) {
        vec2 targetUV = ceHandJoint(0, CE_INDEX_TIP).xy;
        sunPosition = cameraToSphereUV(targetUV, fov, cameraDirection * vec3(1,-1,1));
    }
    
    vec4 color = generate(uv, sunPosition, uTime, vec3(1));

    color = vec4(postProcess(color.rgb, hsb), 1.0);
    outColor = color * 1.0748724675633854;
}
